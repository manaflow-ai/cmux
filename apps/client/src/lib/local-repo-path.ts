const DRIVE_PATH_REGEX = /^[A-Za-z]:[\\/]/;

export const isLikelyLocalPath = (value: string): boolean => {
  if (!value) return false;
  const trimmed = value.trim();
  if (!trimmed) return false;
  return (
    trimmed === "~" ||
    trimmed.startsWith("~/") ||
    trimmed.startsWith("/") ||
    trimmed.startsWith("./") ||
    trimmed.startsWith("../") ||
    DRIVE_PATH_REGEX.test(trimmed) ||
    trimmed.startsWith("\\\\")
  );
};

export const formatLocalDisplayLabel = (
  path: string,
  homeDir?: string | null
): string => {
  if (homeDir && path.startsWith(homeDir)) {
    const suffix = path.slice(homeDir.length);
    return suffix ? `~${suffix}` : "~";
  }
  return path;
};
import type {
  LocalRepoSuggestResponse,
  LocalRepoSuggestion,
} from "@cmux/shared/socket-schemas";

export type {
  LocalRepoSuggestResponse,
  LocalRepoSuggestion,
} from "@cmux/shared/socket-schemas";
