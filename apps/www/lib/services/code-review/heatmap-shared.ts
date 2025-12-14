import { z } from "zod";
import {
  DEFAULT_TOOLTIP_LANGUAGE,
  type TooltipLanguageValue,
} from "./model-config";

const LANGUAGE_NAME_MAP: Record<string, string> = {
  en: "English",
  "zh-Hans": "Simplified Chinese",
  "zh-Hant": "Traditional Chinese",
  ja: "Japanese",
  ko: "Korean",
  es: "Spanish",
  fr: "French",
  de: "German",
  pt: "Portuguese",
  ru: "Russian",
  hi: "Hindi",
  bn: "Bengali",
  te: "Telugu",
  mr: "Marathi",
  ta: "Tamil",
  gu: "Gujarati",
  kn: "Kannada",
  ml: "Malayalam",
  pa: "Punjabi",
  ar: "Arabic",
  vi: "Vietnamese",
  th: "Thai",
  id: "Indonesian",
};

const heatmapLineSchema = z.object({
  line: z.string(),
  shouldBeReviewedScore: z.number().min(0).max(1).optional(),
  shouldReviewWhy: z.string().optional(),
  mostImportantWord: z.string().min(1),
});

export const heatmapSchema = z.object({
  lines: z.array(heatmapLineSchema),
});

export type HeatmapLine = z.infer<typeof heatmapLineSchema>;

export interface HeatmapPromptOptions {
  /** BCP-47 language tag for the review comments (e.g., "en", "ja", "zh-CN") */
  language?: string | null;
}

/**
 * Extracts a BCP-47 language code from an Accept-Language header value.
 * Returns the primary language or null if invalid.
 */
export function parseAcceptLanguage(acceptLanguage: string | null | undefined): string | null {
  if (!acceptLanguage || typeof acceptLanguage !== "string") {
    return null;
  }
  // Accept-Language format: "en-US,en;q=0.9,ja;q=0.8"
  // We want the first (highest priority) language
  const first = acceptLanguage.split(",")[0];
  if (!first) {
    return null;
  }
  // Remove quality factor if present: "en-US;q=0.9" -> "en-US"
  const lang = first.split(";")[0]?.trim();
  if (!lang || lang.length === 0) {
    return null;
  }
  // Validate it looks like a BCP-47 tag (basic check)
  if (!/^[a-zA-Z]{2,3}(-[a-zA-Z0-9]+)*$/.test(lang)) {
    return null;
  }
  return lang;
}

export function buildHeatmapPrompt(
  filePath: string,
  formattedDiff: readonly string[],
  tooltipLanguage: TooltipLanguageValue = DEFAULT_TOOLTIP_LANGUAGE
): string {
  const diffBody =
    formattedDiff.length > 0 ? formattedDiff.join("\n") : "(no diff)";
  const languageName = LANGUAGE_NAME_MAP[tooltipLanguage] ?? "English";
  const languageInstruction =
    tooltipLanguage !== DEFAULT_TOOLTIP_LANGUAGE
      ? `\n- IMPORTANT: Write ALL shouldReviewWhy explanations in ${languageName}. The mostImportantWord should remain as it appears in the code (do not translate code identifiers).`
      : "";
  return `You are preparing a review heatmap for the file "${filePath}".
Return structured data matching the provided schema. Rules:
- Keep the original diff text in the "line" field; it may begin with "+", "-", or " ".
- Include one entry per diff row that matters. Always cover every line that begins with "+" or "-".
- When shouldBeReviewedScore is set, provide a short shouldReviewWhy hint (6-12 words). Leave both absent when the line is fine.
- shouldBeReviewedScore is a number from 0.00 to 1.00 that indicates how careful the reviewer should be when reviewing this line of code.
- mostImportantWord must always be set. Provide the most critical word or identifier from the line (ignore any leading diff marker).
- Keep explanations concise; do not invent code that is not in the diff.
- Anything that feels like it might be off or might warrant a comment should have a high score, even if it's technically correct.
- In most cases, the shouldReviewWhy should follow a template like "<X> <verb> <Y>" (eg. "line is too long" or "code accesses sensitive data").
- It should be understandable by a human and make sense (break the "X is Y" rule if it helps you make it more understandable).
- Non-clean code and ugly code (hard to read for a human) should be given a higher score.${languageInstruction}

Diff:
\`\`\`diff
${diffBody}
\`\`\``;
}

interface SummarizedChunk {
  lineCount: number | null;
  textDelta: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isHeatmapLineCandidate(value: unknown): value is Record<string, unknown> {
  if (!isRecord(value)) {
    return false;
  }

  if (typeof value.line !== "string") {
    return false;
  }

  if (
    value.shouldBeReviewedScore !== undefined &&
    (typeof value.shouldBeReviewedScore !== "number" ||
      value.shouldBeReviewedScore < 0 ||
      value.shouldBeReviewedScore > 1)
  ) {
    return false;
  }

  if (
    value.shouldReviewWhy !== undefined &&
    typeof value.shouldReviewWhy !== "string"
  ) {
    return false;
  }

  if (
    typeof value.mostImportantWord !== "string" ||
    value.mostImportantWord.trim().length === 0
  ) {
    return false;
  }

  return true;
}

export function summarizeHeatmapStreamChunk(chunk: unknown): SummarizedChunk {
  if (!isRecord(chunk)) {
    return { lineCount: null, textDelta: null };
  }

  const typeValue = chunk.type;
  const textDeltaValue = chunk.textDelta;
  const objectValue = chunk.object;

  let textDelta: string | null = null;
  if (typeValue === "text-delta" && typeof textDeltaValue === "string") {
    const trimmed = textDeltaValue.trim();
    textDelta = trimmed.length > 0 ? trimmed : null;
  }

  let lineCount: number | null = null;
  if (typeValue === "object" && isRecord(objectValue)) {
    const linesValue = objectValue.lines;
    if (
      Array.isArray(linesValue) &&
      linesValue.every((line) => isHeatmapLineCandidate(line))
    ) {
      lineCount = linesValue.length;
    }
  }

  return { lineCount, textDelta };
}
