import {
  computeNewLineNumber,
  computeOldLineNumber,
  type FileData,
} from "react-diff-view";
import type { RangeTokenNode } from "react-diff-view";

export type ReviewHeatmapLine = {
  lineNumber: number | null;
  lineText: string | null;
  score: number | null;
  reason: string | null;
  mostImportantWord: string | null;
};

export type DiffHeatmap = {
  lineClasses: Map<number, string>;
  oldLineClasses: Map<number, string>;
  newRanges: HeatmapRangeNode[];
  entries: Map<number, ResolvedHeatmapLine>;
  oldEntries: Map<number, ResolvedHeatmapLine>;
  totalEntries: number;
};

export type BuildDiffHeatmapOptions = {
  scoreThreshold?: number;
};

export type HeatmapRangeNode = RangeTokenNode & {
  className: string;
};

export type ResolvedHeatmapLine = {
  side: DiffLineSide;
  lineNumber: number;
  score: number | null;
  reason: string | null;
  mostImportantWord: string | null;
};

type DiffLineSide = "new" | "old";

type CollectedLineContent = {
  newLines: Map<number, string>;
  oldLines: Map<number, string>;
};

const SCORE_CLAMP_MIN = 0;
const SCORE_CLAMP_MAX = 1;

const HEATMAP_TIERS = [0.2, 0.4, 0.6, 0.8] as const;

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
    const mostImportantWord = parseNullableString(
      record.mostImportantWord
    );

    parsed.push({
      lineNumber,
      lineText,
      score: normalizedScore,
      reason,
      mostImportantWord,
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
  reviewHeatmap: ReviewHeatmapLine[],
  options: BuildDiffHeatmapOptions = {}
): DiffHeatmap | null {
  if (!diff || reviewHeatmap.length === 0) {
    return null;
  }

  const lineContent = collectLineContent(diff);

  const resolvedEntries = resolveLineNumbers(reviewHeatmap, lineContent);
  if (resolvedEntries.length === 0) {
    return null;
  }

  const aggregated = aggregateEntries(resolvedEntries);
  if (aggregated.size === 0) {
    return null;
  }

  const threshold = options.scoreThreshold ?? SCORE_CLAMP_MIN;
  const normalizedThreshold = clamp(
    threshold,
    SCORE_CLAMP_MIN,
    SCORE_CLAMP_MAX
  );
  const filtered = filterEntriesByThreshold(aggregated, normalizedThreshold);
  if (filtered.size === 0) {
    return null;
  }

  const lineClasses = new Map<number, string>();
  const oldLineClasses = new Map<number, string>();
  const characterRanges: HeatmapRangeNode[] = [];
  const entries = new Map<number, ResolvedHeatmapLine>();
  const oldEntries = new Map<number, ResolvedHeatmapLine>();

  for (const entry of filtered.values()) {
    const targetEntries = entry.side === "new" ? entries : oldEntries;
    targetEntries.set(entry.lineNumber, entry);

    const normalizedScore =
      entry.score === null
        ? null
        : clamp(entry.score, SCORE_CLAMP_MIN, SCORE_CLAMP_MAX);
    const tier = computeHeatmapTier(normalizedScore);

    if (tier > 0) {
      const targetClassMap =
        entry.side === "new" ? lineClasses : oldLineClasses;
      targetClassMap.set(entry.lineNumber, `cmux-heatmap-tier-${tier}`);
    }

    if (
      entry.side === "old" ||
      !entry.mostImportantWord
    ) {
      continue;
    }

    const content = lineContent.newLines.get(entry.lineNumber);
    if (!content || content.length === 0) {
      continue;
    }

    const highlight = deriveHighlightRange(content, entry.mostImportantWord);
    if (!highlight) {
      continue;
    }

    const highlightIndex = clamp(
      highlight.start,
      0,
      Math.max(content.length - 1, 0)
    );
    const highlightLength = clamp(
      Math.floor(highlight.length),
      1,
      Math.max(content.length - highlightIndex, 1)
    );

    const charTier = tier > 0 ? tier : 1;
    const range: HeatmapRangeNode = {
      type: "span",
      lineNumber: entry.lineNumber,
      start: highlightIndex,
      length: highlightLength,
      className: `cmux-heatmap-char cmux-heatmap-char-tier-${charTier}`,
    };
    characterRanges.push(range);
  }

  if (
    lineClasses.size === 0 &&
    oldLineClasses.size === 0 &&
    characterRanges.length === 0
  ) {
    return null;
  }

  return {
    lineClasses,
    oldLineClasses,
    newRanges: characterRanges,
    entries,
    oldEntries,
    totalEntries: filtered.size,
  };
}

function aggregateEntries(
  entries: ResolvedHeatmapLine[]
): Map<string, ResolvedHeatmapLine> {
  const aggregated = new Map<string, ResolvedHeatmapLine>();

  for (const entry of entries) {
    const key = buildLineKey(entry.side, entry.lineNumber);
    const current = aggregated.get(key);

    if (!current) {
      aggregated.set(key, { ...entry });
      continue;
    }

    const currentScore = current.score ?? SCORE_CLAMP_MIN;
    const nextScore = entry.score ?? SCORE_CLAMP_MIN;
    const shouldReplaceScore = nextScore > currentScore;

    aggregated.set(key, {
      lineNumber: entry.lineNumber,
      side: entry.side,
      score: shouldReplaceScore ? entry.score : current.score,
      reason: entry.reason ?? current.reason,
      mostImportantWord:
        entry.mostImportantWord ?? current.mostImportantWord,
    });
  }

  return aggregated;
}

function filterEntriesByThreshold(
  entries: Map<string, ResolvedHeatmapLine>,
  threshold: number
): Map<string, ResolvedHeatmapLine> {
  if (threshold <= SCORE_CLAMP_MIN) {
    return entries;
  }

  const filtered = new Map<string, ResolvedHeatmapLine>();

  for (const [key, entry] of entries.entries()) {
    const score = entry.score ?? SCORE_CLAMP_MIN;
    if (score >= threshold) {
      filtered.set(key, entry);
    }
  }

  return filtered;
}

function buildLineKey(side: DiffLineSide, lineNumber: number): string {
  return `${side}:${lineNumber}`;
}

function resolveLineNumbers(
  entries: ReviewHeatmapLine[],
  lineContent: CollectedLineContent
): ResolvedHeatmapLine[] {
  const resolved: ResolvedHeatmapLine[] = [];
  const { newLines, oldLines } = lineContent;
  const newLineEntries = Array.from(newLines.entries());
  const oldLineEntries = Array.from(oldLines.entries());
  const newSearchOffsets = new Map<string, number>();
  const oldSearchOffsets = new Map<string, number>();

  for (const entry of entries) {
    if (entry.score === null) {
      continue;
    }

    const directMatch = resolveDirectLineNumber(
      entry,
      lineContent
    );

    if (directMatch) {
      resolved.push({
        side: directMatch.side,
        lineNumber: directMatch.lineNumber,
        score: entry.score,
        reason: entry.reason,
        mostImportantWord: entry.mostImportantWord,
      });
      continue;
    }

    const normalizedTarget = toSearchableText(entry.lineText);
    if (normalizedTarget) {
      const newCandidate = findLineByText(
        normalizedTarget,
        newLineEntries,
        newSearchOffsets
      );
      if (newCandidate !== null) {
        resolved.push({
          side: "new",
          lineNumber: newCandidate,
          score: entry.score,
          reason: entry.reason,
          mostImportantWord: entry.mostImportantWord,
        });
        continue;
      }

      const oldCandidate = findLineByText(
        normalizedTarget,
        oldLineEntries,
        oldSearchOffsets
      );
      if (oldCandidate !== null) {
        resolved.push({
          side: "old",
          lineNumber: oldCandidate,
          score: entry.score,
          reason: entry.reason,
          mostImportantWord: entry.mostImportantWord,
        });
        continue;
      }
    }

    const normalizedKeyword = toSearchableText(entry.mostImportantWord);
    if (!normalizedKeyword) {
      continue;
    }

    const keywordNewCandidate = findLineByText(
      normalizedKeyword,
      newLineEntries,
      newSearchOffsets
    );
    if (keywordNewCandidate !== null) {
      resolved.push({
        side: "new",
        lineNumber: keywordNewCandidate,
        score: entry.score,
        reason: entry.reason,
        mostImportantWord: entry.mostImportantWord,
      });
      continue;
    }

    const keywordOldCandidate = findLineByText(
      normalizedKeyword,
      oldLineEntries,
      oldSearchOffsets
    );
    if (keywordOldCandidate !== null) {
      resolved.push({
        side: "old",
        lineNumber: keywordOldCandidate,
        score: entry.score,
        reason: entry.reason,
        mostImportantWord: entry.mostImportantWord,
      });
    }
  }

  return resolved;
}

function resolveDirectLineNumber(
  entry: ReviewHeatmapLine,
  lineContent: CollectedLineContent
): { side: DiffLineSide; lineNumber: number } | null {
  const { lineNumber } = entry;
  if (!lineNumber) {
    return null;
  }

  const { newLines, oldLines } = lineContent;
  const hasNew = newLines.has(lineNumber);
  const hasOld = oldLines.has(lineNumber);

  if (!hasNew && !hasOld) {
    return null;
  }

  if (hasNew && !hasOld) {
    return doesLineContentMatch(entry, newLines.get(lineNumber))
      ? { side: "new", lineNumber }
      : null;
  }

  if (!hasNew && hasOld) {
    return doesLineContentMatch(entry, oldLines.get(lineNumber))
      ? { side: "old", lineNumber }
      : null;
  }

  const matchesNew = doesLineContentMatch(entry, newLines.get(lineNumber));
  const matchesOld = doesLineContentMatch(entry, oldLines.get(lineNumber));

  if (matchesNew && !matchesOld) {
    return { side: "new", lineNumber };
  }

  if (matchesOld && !matchesNew) {
    return { side: "old", lineNumber };
  }

  if (matchesNew && matchesOld) {
    return { side: "new", lineNumber };
  }

  return null;
}

function doesLineContentMatch(
  entry: ReviewHeatmapLine,
  rawContent: string | null | undefined
): boolean {
  const normalizedContent = toSearchableText(rawContent);
  if (!normalizedContent) {
    return false;
  }

  const normalizedTarget = toSearchableText(entry.lineText);
  if (normalizedTarget && normalizedContent.includes(normalizedTarget)) {
    return true;
  }

  const normalizedWord = toSearchableText(entry.mostImportantWord);
  if (normalizedWord && normalizedContent.includes(normalizedWord)) {
    return true;
  }

  return !normalizedTarget && !normalizedWord;
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
    const normalizedSource = toSearchableText(rawText);
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

  const { content } = stripDiffMarker(value);
  const normalized = content.replace(/\s+/g, " ").trim();
  return normalized.length > 0 ? normalized : null;
}

function toSearchableText(value: string | null | undefined): string | null {
  const normalized = normalizeLineText(value);
  return normalized ? normalized.toLowerCase() : null;
}

function collectLineContent(diff: FileData): CollectedLineContent {
  const newLines = new Map<number, string>();
  const oldLines = new Map<number, string>();

  for (const hunk of diff.hunks) {
    for (const change of hunk.changes) {
      const newLineNumber = computeNewLineNumber(change);
      if (newLineNumber > 0) {
        newLines.set(newLineNumber, change.content ?? "");
      }

      const oldLineNumber = computeOldLineNumber(change);
      if (oldLineNumber > 0) {
        oldLines.set(oldLineNumber, change.content ?? "");
      }
    }
  }

  return {
    newLines,
    oldLines,
  };
}

function deriveHighlightRange(
  rawContent: string,
  mostImportantWord: string | null
): { start: number; length: number } | null {
  if (!rawContent || !mostImportantWord) {
    return null;
  }

  const trimmedWord = mostImportantWord.trim();
  if (!trimmedWord) {
    return null;
  }

  const { content, offset } = stripDiffMarker(rawContent);
  if (!content) {
    return null;
  }

  const candidates = buildHighlightCandidates(trimmedWord);
  if (candidates.length === 0) {
    return null;
  }

  const lowerContent = content.toLowerCase();

  for (const candidate of candidates) {
    const directIndex = content.indexOf(candidate);
    if (directIndex >= 0) {
      return {
        start: directIndex + offset,
        length: Math.max(candidate.length, 1),
      };
    }

    const lowerCandidate = candidate.toLowerCase();
    const lowerIndex = lowerContent.indexOf(lowerCandidate);
    if (lowerIndex >= 0) {
      return {
        start: lowerIndex + offset,
        length: Math.max(candidate.length, 1),
      };
    }
  }

  const fallbackIndex = content.search(/\S/);
  if (fallbackIndex >= 0) {
    return {
      start: fallbackIndex + offset,
      length: 1,
    };
  }

  return null;
}

function stripDiffMarker(value: string): { content: string; offset: number } {
  if (!value) {
    return { content: "", offset: 0 };
  }

  const firstChar = value[0] ?? "";
  if (firstChar === "+" || firstChar === "-" || firstChar === " ") {
    return { content: value.slice(1), offset: 1 };
  }

  return { content: value, offset: 0 };
}

function buildHighlightCandidates(word: string): string[] {
  const candidates = new Set<string>();

  const addCandidate = (value: string | null | undefined): void => {
    if (!value) {
      return;
    }
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return;
    }
    candidates.add(trimmed);
  };

  const base = stripSurroundingQuotes(word.trim());
  addCandidate(word);
  addCandidate(base);
  addCandidate(sanitizeHighlightToken(base));

  const tokens = base.split(/\s+/).filter(Boolean);
  for (const token of tokens) {
    addCandidate(token);
    addCandidate(sanitizeHighlightToken(token));

    if (token.includes(".")) {
      for (const segment of token.split(".").filter(Boolean)) {
        addCandidate(segment);
        addCandidate(sanitizeHighlightToken(segment));
      }
    }
  }

  return Array.from(candidates);
}

function stripSurroundingQuotes(value: string): string {
  return value.replace(/^["'`]+|["'`]+$/g, "");
}

function sanitizeHighlightToken(value: string): string {
  return value.replace(/^[^A-Za-z0-9_$]+/, "").replace(/[^A-Za-z0-9_$]+$/, "");
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
  if (typeof value === "number" && Number.isFinite(value)) {
    const integer = Math.floor(value);
    return integer > 0 ? integer : null;
  }

  if (typeof value !== "string") {
    return null;
  }

  const candidate = extractLineNumberCandidate(value);
  if (!candidate) {
    return null;
  }

  const numeric = parseNullableNumber(candidate);
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

function extractLineNumberCandidate(value: string): string | null {
  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }

  if (/^[+-]?\d+(\.\d+)?$/.test(trimmed)) {
    return trimmed;
  }

  const lineMatch =
    trimmed.match(/^line\s*([+-]?\d+(?:\.\d+)?)(?:\s*[:\-–])?$/i);
  if (lineMatch && lineMatch[1]) {
    return lineMatch[1];
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
