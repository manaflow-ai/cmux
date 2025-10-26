import { jsonLinesStrategy } from "./json-lines";
import { lineNumbersStrategy } from "./line-numbers";
import { openAiResponsesStrategy } from "./openai-responses";
import { inlinePhraseStrategy } from "./inline-phrase";
import { inlineBracketsStrategy } from "./inline-brackets";
import { inlineJsonStrategy } from "./inline-json";
import { inlineFilesStrategy } from "./inline-files";
import type { ReviewStrategy } from "../core/types";
import type { PrReviewStrategyId } from "../core/options";

const STRATEGY_MAP: Record<PrReviewStrategyId, ReviewStrategy> = {
  "json-lines": jsonLinesStrategy,
  "line-numbers": lineNumbersStrategy,
  "openai-responses": openAiResponsesStrategy,
  "inline-phrase": inlinePhraseStrategy,
  "inline-brackets": inlineBracketsStrategy,
  "inline-json": inlineJsonStrategy,
  "inline-files": inlineFilesStrategy,
};

export function resolveStrategy(id: PrReviewStrategyId): ReviewStrategy {
  return STRATEGY_MAP[id];
}

export const AVAILABLE_STRATEGIES: ReviewStrategy[] = Object.values(
  STRATEGY_MAP
);
