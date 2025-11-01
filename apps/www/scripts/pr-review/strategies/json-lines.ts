import { z } from "zod";
import type {
  ReviewStrategy,
  StrategyPrepareContext,
  StrategyPrepareResult,
  StrategyProcessContext,
  StrategyRunResult,
} from "../core/types";

export interface JsonLinesPromptInput {
  filePath: string;
  diff: string;
  formattedDiff: string[];
  showDiffLineNumbers: boolean;
  showContextLineNumbers: boolean;
}

export function buildJsonLinesPrompt({
  filePath,
  diff,
  formattedDiff,
  showDiffLineNumbers,
  showContextLineNumbers,
}: JsonLinesPromptInput): string {
  const diffForPrompt =
    showDiffLineNumbers || showContextLineNumbers
      ? formattedDiff.join("\n")
      : diff || "(no diff output)";

  return `You are a senior engineer performing a focused pull request review, focusing only on the diffs in the file provided.
File path: ${filePath}
Return a JSON object of type { lines: { line: string, shouldBeReviewedScore: number, shouldReviewWhy: string | null, mostImportantWord: string }[] }.
You should only have the "post-diff" array of lines in the JSON object.
The "line" property MUST contain the exact line of code you want a human to review (no truncation, no summaries).
shouldBeReviewedScore is a number between 0.0 and 1.0 (always include it even if 0.0) that indicates how careful the reviewer should be when reviewing this line of code.
Anything that feels like it might be off or might warrant a comment should have a high score, even if it's technically correct.
shouldReviewWhy should be a concise (4-10 words) hint on why the reviewer should maybe review this line of code, but it shouldn't state obvious things, instead it should only be a hint for the reviewer as to what exactly you meant when you flagged it.
In most cases, the reason should follow a template like "<X> <verb> <Y>" (eg. "line is too long" or "code accesses sensitive data").
It should be understandable by a human and make sense (break the "X is Y" rule if it helps you make it more understandable).
mostImportantWord must always be provided and should identify the most critical word or identifier in the line. If you're unsure, pick the earliest relevant word or token.
Ugly code should be given a higher score.
Code that may be hard to read for a human should also be given a higher score.
Non-clean code too. Type casts, type assertions, type guards, "any" types, untyped bodies to "fetch" etc. should be given a higher score.
DO NOT BE LAZY. DO THE ENTIRE FILE. FROM START TO FINISH. DO NOT BE LAZY.

The diff:
${diffForPrompt || "(no diff output)"}`;
}

export const jsonLinesOutputSchema = {
  type: "object",
  properties: {
    lines: {
      type: "array",
      items: {
        type: "object",
        properties: {
          line: { type: "string" },
          shouldBeReviewedScore: { type: "number" },
          shouldReviewWhy: { type: ["string", "null"] as const },
          mostImportantWord: { type: "string" },
        },
        required: [
          "line",
          "shouldBeReviewedScore",
          "shouldReviewWhy",
          "mostImportantWord",
        ],
        additionalProperties: false,
      },
    },
  },
  required: ["lines"],
  additionalProperties: false,
} as const;

export const jsonLinesZodSchema = z.object({
  lines: z.array(
    z.object({
      line: z.string(),
      shouldBeReviewedScore: z.number().min(0).max(1),
      shouldReviewWhy: z.string().nullable(),
      mostImportantWord: z.string().min(1),
    })
  ),
});

export type JsonLinesResult = z.infer<typeof jsonLinesZodSchema>;

async function prepare(
  context: StrategyPrepareContext
): Promise<StrategyPrepareResult> {
  const prompt = buildJsonLinesPrompt({
    filePath: context.filePath,
    diff: context.diff,
    formattedDiff: context.formattedDiff,
    showDiffLineNumbers: context.options.showDiffLineNumbers,
    showContextLineNumbers: context.options.showContextLineNumbers,
  });
  return {
    prompt,
    outputSchema: jsonLinesOutputSchema,
  };
}

async function process(
  context: StrategyProcessContext
): Promise<StrategyRunResult> {
  return {
    rawResponse: context.responseText,
  };
}

export const jsonLinesStrategy: ReviewStrategy = {
  id: "json-lines",
  displayName: "JSON (line content)",
  prepare,
  process,
};
