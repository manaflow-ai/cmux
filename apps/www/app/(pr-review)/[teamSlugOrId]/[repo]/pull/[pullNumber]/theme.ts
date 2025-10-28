export type ThemePreference = "light" | "dark";

export const DEFAULT_THEME: ThemePreference = "light";
export const THEME_COOKIE_NAME = "pr-review-theme";

export function isThemePreference(value: unknown): value is ThemePreference {
  return value === "light" || value === "dark";
}
