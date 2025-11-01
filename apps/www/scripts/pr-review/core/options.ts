import { dirname, join } from "node:path";

export type PrReviewStrategyId =
  | "json-lines"
  | "json-lines-direct"
  | "line-numbers"
  | "openai-responses"
  | "inline-phrase"
  | "inline-brackets"
  | "inline-json"
  | "inline-files"
  | "heatmap";

export interface PrReviewOptions {
  strategy: PrReviewStrategyId;
  showDiffLineNumbers: boolean;
  showContextLineNumbers: boolean;
  workspaceDir: string;
  artifactsDir: string;
  diffArtifactMode: DiffArtifactMode;
}

const STRATEGY_VALUES: PrReviewStrategyId[] = [
  "json-lines",
  "json-lines-direct",
  "line-numbers",
  "openai-responses",
  "inline-phrase",
  "inline-brackets",
  "inline-json",
  "inline-files",
  "heatmap",
];

export type DiffArtifactMode = "single" | "per-file";

const DIFF_ARTIFACT_VALUES: DiffArtifactMode[] = ["single", "per-file"];

function parseBooleanEnv(value: string | undefined, defaultValue: boolean): boolean {
  if (value === undefined) return defaultValue;
  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "y", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "n", "off"].includes(normalized)) return false;
  return defaultValue;
}

function parseStrategy(value: string | undefined, fallback: PrReviewStrategyId): PrReviewStrategyId {
  if (!value) return fallback;
  const normalized = value.trim().toLowerCase();
  if (STRATEGY_VALUES.includes(normalized as PrReviewStrategyId)) {
    return normalized as PrReviewStrategyId;
  }
  return fallback;
}

function parseDiffArtifactMode(
  value: string | undefined,
  fallback: DiffArtifactMode
): DiffArtifactMode {
  if (!value) return fallback;
  const normalized = value.trim().toLowerCase();
  if (DIFF_ARTIFACT_VALUES.includes(normalized as DiffArtifactMode)) {
    return normalized as DiffArtifactMode;
  }
  return fallback;
}

export function loadOptionsFromEnv(env: NodeJS.ProcessEnv): PrReviewOptions {
  const strategy = parseStrategy(env.CMUX_PR_REVIEW_STRATEGY, "json-lines");
  const showDiffLineNumbers = parseBooleanEnv(
    env.CMUX_PR_REVIEW_SHOW_DIFF_LINE_NUMBERS,
    false
  );
  const showContextLineNumbers = parseBooleanEnv(
    env.CMUX_PR_REVIEW_SHOW_CONTEXT_LINE_NUMBERS,
    true
  );
  const workspaceDir = env.WORKSPACE_DIR ?? "/workspace";
  const artifactsDir =
    env.CMUX_PR_REVIEW_ARTIFACTS_DIR ??
    join(workspaceDir, ".cmux-pr-review-artifacts");
  const diffArtifactMode = parseDiffArtifactMode(
    env.CMUX_PR_REVIEW_DIFF_ARTIFACT_MODE,
    "per-file"
  );

  return {
    strategy,
    showDiffLineNumbers,
    showContextLineNumbers,
    workspaceDir,
    artifactsDir,
    diffArtifactMode,
  };
}

export function ensureArtifactsSubdir(
  artifactsDir: string,
  ...segments: string[]
): string {
  return join(artifactsDir, ...segments);
}

export function getRelativeArtifactsRoot(options: PrReviewOptions): string {
  const parent = dirname(options.artifactsDir);
  if (parent === ".") {
    return options.artifactsDir;
  }
  return options.artifactsDir;
}
