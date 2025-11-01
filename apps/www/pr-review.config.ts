/**
 * Global PR Review Configuration
 *
 * This file controls the default strategy used for PR reviews.
 * Change the PR_REVIEW_STRATEGY value to switch between different review strategies.
 *
 * Available strategies:
 * - "heatmap": New structured diff analysis with changeType tracking
 * - "json-lines": Original JSON strategy with line content
 * - "line-numbers": Strategy using line numbers
 * - "openai-responses": Strategy using OpenAI response format
 * - "inline-phrase": Inline phrase-based annotations
 * - "inline-brackets": Inline bracket-based annotations
 * - "inline-json": Inline JSON annotations
 * - "inline-files": Inline file-based annotations
 */

export const PR_REVIEW_STRATEGY = "json-lines-direct" as const;

export const PR_REVIEW_CONFIG = {
  strategy: PR_REVIEW_STRATEGY,

  // You can override these with environment variables:
  // - CMUX_PR_REVIEW_STRATEGY
  // - CMUX_PR_REVIEW_SHOW_DIFF_LINE_NUMBERS
  // - CMUX_PR_REVIEW_SHOW_CONTEXT_LINE_NUMBERS
  // - CMUX_PR_REVIEW_DIFF_ARTIFACT_MODE
} as const;
