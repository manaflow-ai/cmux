import { computeNewLineNumber, isDelete, type FileData } from "react-diff-view";
import type { RangeTokenNode } from "react-diff-view";

export type ReviewHeatmapLine = {
  lineNumber: number | null;
  lineText: string | null;
  score: number | null;
  reason: string | null;
  mostImportantCharacterIndex: number | null;
};

export type DiffHeatmap = {
  lineClasses: Map<number, string>;
  newRanges: HeatmapRangeNode[];
  entries: Map<number, ResolvedHeatmapLine>;
};

export type HeatmapRangeNode = RangeTokenNode & {
  className: string;
  heatmapTier: number;
  heatmapScore: number;
};

type ResolvedHeatmapLine = {
  lineNumber: number;
  score: number | null;
  reason: string | null;
  mostImportantCharacterIndex: number | null;
};

const SCORE_CLAMP_MIN = 0;
const SCORE_CLAMP_MAX = 1;

export const HEATMAP_SCORE_BREAKPOINTS = [
  0.15,
  0.3,
  0.5,
  0.7,
  0.85,
  0.95,
] as const;

const HEATMAP_TIERS = HEATMAP_SCORE_BREAKPOINTS;

export function scoreToHeatmapColor(
  score: number,
  options?: { alpha?: number }
): string {
  const alpha = options?.alpha ?? 0.35;
  const normalized = clamp(score, SCORE_CLAMP_MIN, SCORE_CLAMP_MAX);
  const hue = Math.max(0, Math.min(120, Math.round((1 - normalized) * 120)));
  return `hsla(${hue}, 95%, 38%, ${alpha})`;
}

export function parseReviewHeatmap(raw: unknown): ReviewHeatmapLine[] {
  const payload = unwrapCodexPayload(raw);
  if (!payload || typeof payload !== "object") {
    return [];
  }

  const lines = Array.isArray((payload as { lines?: unknown }).lines)
    ? ((payload as { lines: unknown[] }).lines ?? [])
    : [];

  const parsed: ReviewHeatmapLine[] = [];

  for (const entry of lines) {
    if (typeof entry !== "object" || entry === null) {
      continue;
    }

    const record = entry as Record<string, unknown>;
    const lineNumber = parseLineNumber(record.line);
    const lineText =
      typeof record.line === "string" ? record.line.trim() : null;

    if (lineNumber === null && !lineText) {
      continue;
    }

    const rawScore = parseNullableNumber(record.shouldBeReviewedScore);
    const normalizedScore =
      rawScore === null
        ? null
        : clamp(rawScore, SCORE_CLAMP_MIN, SCORE_CLAMP_MAX);

    if (normalizedScore === null || normalizedScore <= 0) {
      continue;
    }

    const reason = parseNullableString(record.shouldReviewWhy);
    const mostImportantCharacterIndex = parseNullableInteger(
      record.mostImportantCharacterIndex
    );

    parsed.push({
      lineNumber,
      lineText,
      score: normalizedScore,
      reason,
      mostImportantCharacterIndex,
    });
  }

  parsed.sort((a, b) => {
    const aLine = a.lineNumber ?? Number.MAX_SAFE_INTEGER;
    const bLine = b.lineNumber ?? Number.MAX_SAFE_INTEGER;
    if (aLine !== bLine) {
      return aLine - bLine;
    }
    return (a.lineText ?? "").localeCompare(b.lineText ?? "");
  });
  return parsed;
}

export function buildDiffHeatmap(
  diff: FileData | null,
  reviewHeatmap: ReviewHeatmapLine[]
): DiffHeatmap | null {
  if (!diff || reviewHeatmap.length === 0) {
    return null;
  }

  const newLineContent = collectNewLineContent(diff);

  const resolvedEntries = resolveLineNumbers(reviewHeatmap, newLineContent);
  if (resolvedEntries.length === 0) {
    return null;
  }

  const aggregated = aggregateEntries(resolvedEntries);
  if (aggregated.size === 0) {
    return null;
  }

  const lineClasses = new Map<number, string>();
  const characterRanges: HeatmapRangeNode[] = [];

  for (const [lineNumber, entry] of aggregated.entries()) {
    const normalizedScore =
      entry.score === null
        ? null
        : clamp(entry.score, SCORE_CLAMP_MIN, SCORE_CLAMP_MAX);
    const tier = computeHeatmapTier(normalizedScore);

    if (tier > 0) {
      lineClasses.set(lineNumber, `cmux-heatmap-tier-${tier}`);
    }

    if (entry.mostImportantCharacterIndex === null) {
      continue;
    }

    const content = newLineContent.get(lineNumber);
    if (!content || content.length === 0) {
      continue;
    }

    const highlightIndex = clamp(
      Math.floor(entry.mostImportantCharacterIndex),
      0,
      Math.max(content.length - 1, 0)
    );
    const highlightRange = expandHighlightRange(content, highlightIndex);
    if (highlightRange.length <= 0) {
      continue;
    }

    const charTier = tier > 0 ? tier : 1;
    const range: HeatmapRangeNode = {
      type: "span",
      lineNumber,
      start: highlightRange.start,
      length: highlightRange.length,
      className: `cmux-heatmap-char cmux-heatmap-char-tier-${charTier}`,
      heatmapTier: charTier,
      heatmapScore: normalizedScore ?? SCORE_CLAMP_MIN,
    };
    characterRanges.push(range);
  }

  if (lineClasses.size === 0 && characterRanges.length === 0) {
    return null;
  }

  return {
    lineClasses,
    newRanges: characterRanges,
    entries: aggregated,
  };
}

function aggregateEntries(
  entries: ResolvedHeatmapLine[]
): Map<number, ResolvedHeatmapLine> {
  const aggregated = new Map<number, ResolvedHeatmapLine>();

  for (const entry of entries) {
    const current = aggregated.get(entry.lineNumber);

    if (!current) {
      aggregated.set(entry.lineNumber, { ...entry });
      continue;
    }

    const currentScore = current.score ?? SCORE_CLAMP_MIN;
    const nextScore = entry.score ?? SCORE_CLAMP_MIN;
    const shouldReplaceScore = nextScore > currentScore;

    aggregated.set(entry.lineNumber, {
      lineNumber: entry.lineNumber,
      score: shouldReplaceScore ? entry.score : current.score,
      reason: entry.reason ?? current.reason,
      mostImportantCharacterIndex:
        entry.mostImportantCharacterIndex ?? current.mostImportantCharacterIndex,
    });
  }

  return aggregated;
}

function resolveLineNumbers(
  entries: ReviewHeatmapLine[],
  lineContent: Map<number, string>
): ResolvedHeatmapLine[] {
  const resolved: ResolvedHeatmapLine[] = [];
  const lineEntries = Array.from(lineContent.entries());
  const searchOffsets = new Map<string, number>();

  for (const entry of entries) {
    if (entry.score === null) {
      continue;
    }

    const directLine =
      entry.lineNumber && lineContent.has(entry.lineNumber)
        ? entry.lineNumber
        : null;

    if (directLine) {
      resolved.push({
        lineNumber: directLine,
        score: entry.score,
        reason: entry.reason,
        mostImportantCharacterIndex: entry.mostImportantCharacterIndex,
      });
      continue;
    }

    const normalizedTarget = normalizeLineText(entry.lineText);
    if (!normalizedTarget) {
      continue;
    }

    const candidate = findLineByText(
      normalizedTarget,
      lineEntries,
      searchOffsets
    );

    if (candidate !== null) {
      resolved.push({
        lineNumber: candidate,
        score: entry.score,
        reason: entry.reason,
        mostImportantCharacterIndex: entry.mostImportantCharacterIndex,
      });
    }
  }

  return resolved;
}

function findLineByText(
  normalizedTarget: string,
  lineEntries: Array<[number, string]>,
  searchOffsets: Map<string, number>
): number | null {
  const entriesCount = lineEntries.length;
  const startIndex = searchOffsets.get(normalizedTarget) ?? 0;

  for (let index = startIndex; index < entriesCount; index += 1) {
    const [lineNumber, rawText] = lineEntries[index]!;
    const normalizedSource = normalizeLineText(rawText);
    if (!normalizedSource) {
      continue;
    }

    if (normalizedSource === normalizedTarget) {
      searchOffsets.set(normalizedTarget, index + 1);
      return lineNumber;
    }

    if (normalizedSource.includes(normalizedTarget)) {
      searchOffsets.set(normalizedTarget, index + 1);
      return lineNumber;
    }
  }

  searchOffsets.set(normalizedTarget, entriesCount);
  return null;
}

function normalizeLineText(value: string | null | undefined): string | null {
  if (!value) {
    return null;
  }

  return value.replace(/\s+/g, " ").trim();
}

function collectNewLineContent(diff: FileData): Map<number, string> {
  const map = new Map<number, string>();

  for (const hunk of diff.hunks) {
    for (const change of hunk.changes) {
      const lineNumber = computeNewLineNumber(change);
      if (lineNumber < 0) {
        continue;
      }

      if (isDelete(change)) {
        continue;
      }

      map.set(lineNumber, change.content ?? "");
    }
  }

  return map;
}

function expandHighlightRange(
  content: string,
  targetIndex: number
): { start: number; length: number } {
  if (content.length === 0) {
    return { start: 0, length: 0 };
  }

  const sanitizedIndex = clamp(
    Math.floor(targetIndex),
    0,
    Math.max(content.length - 1, 0)
  );
  const diffPrefixLength = /^[+\- ]/.test(content) ? 1 : 0;
  let searchIndex = Math.max(sanitizedIndex, diffPrefixLength);

  const isIdentifierChar = (char: string) => /[A-Za-z0-9_$]/.test(char);
  const isWhitespace = (char: string) => /\s/.test(char);

  if (isWhitespace(content[searchIndex] ?? "")) {
    let forward = searchIndex + 1;
    while (forward < content.length && isWhitespace(content[forward] ?? "")) {
      forward += 1;
    }

    if (forward < content.length) {
      searchIndex = Math.max(forward, diffPrefixLength);
    } else {
      let backward = searchIndex - 1;
      while (backward >= diffPrefixLength && isWhitespace(content[backward] ?? "")) {
        backward -= 1;
      }
      if (backward >= diffPrefixLength) {
        searchIndex = backward;
      }
    }
  }

  let start = searchIndex;
  let end = searchIndex + 1;
  const currentChar = content[searchIndex] ?? "";

  if (isIdentifierChar(currentChar)) {
    while (start > diffPrefixLength && isIdentifierChar(content[start - 1] ?? "")) {
      start -= 1;
    }
    while (end < content.length && isIdentifierChar(content[end] ?? "")) {
      end += 1;
    }
  } else if (!isWhitespace(currentChar)) {
    while (start > diffPrefixLength && !isWhitespace(content[start - 1] ?? "")) {
      start -= 1;
    }
    while (end < content.length && !isWhitespace(content[end] ?? "")) {
      end += 1;
    }
  }

  const fallbackLength = 3;
  if (end - start <= 0) {
    start = Math.max(searchIndex - 1, diffPrefixLength);
    end = Math.min(start + fallbackLength, content.length);
  }

  const length = Math.max(Math.min(end - start, content.length - start), 1);
  return { start, length };
}

function computeHeatmapTier(score: number | null): number {
  if (score === null) {
    return 0;
  }

  for (let index = HEATMAP_TIERS.length - 1; index >= 0; index -= 1) {
    if (score >= HEATMAP_TIERS[index]!) {
      return index + 1;
    }
  }

  return score > 0 ? 1 : 0;
}

function clamp(value: number, min: number, max: number): number {
  if (Number.isNaN(value)) {
    return min;
  }
  return Math.min(Math.max(value, min), max);
}

function parseLineNumber(value: unknown): number | null {
  const numeric = parseNullableNumber(value);
  if (numeric === null) {
    return null;
  }

  const integer = Math.floor(numeric);
  return Number.isFinite(integer) && integer > 0 ? integer : null;
}

function parseNullableNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }

  if (typeof value === "string") {
    const match = value.match(/-?\d+(\.\d+)?/);
    if (!match) {
      return null;
    }
    const parsed = Number.parseFloat(match[0] ?? "");
    return Number.isFinite(parsed) ? parsed : null;
  }

  return null;
}

function parseNullableInteger(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.floor(value);
  }

  if (typeof value === "string") {
    const match = value.match(/-?\d+/);
    if (!match) {
      return null;
    }
    const parsed = Number.parseInt(match[0] ?? "", 10);
    return Number.isFinite(parsed) ? parsed : null;
  }

  return null;
}

function parseNullableString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function unwrapCodexPayload(value: unknown): unknown {
  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) {
      return null;
    }

    try {
      return unwrapCodexPayload(JSON.parse(trimmed));
    } catch {
      return null;
    }
  }

  if (typeof value === "object") {
    const record = value as Record<string, unknown>;

    if (typeof record.response === "string" || typeof record.response === "object") {
      return unwrapCodexPayload(record.response);
    }

    if (
      typeof record.payload === "string" ||
      typeof record.payload === "object"
    ) {
      return unwrapCodexPayload(record.payload);
    }

    if (Array.isArray(record.lines)) {
      return record;
    }
  }

  return null;
}
