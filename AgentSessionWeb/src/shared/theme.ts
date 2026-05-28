import type { AgentSessionTheme } from "./types";

const cssVariables: Record<keyof AgentSessionTheme, string | null> = {
  isDark: null,
  pageBackground: "--agent-page-bg",
  surfaceBackground: "--agent-surface",
  surfaceElevatedBackground: "--agent-surface-elevated",
  inputBackground: "--agent-input-bg",
  border: "--agent-border",
  borderStrong: "--agent-border-strong",
  text: "--agent-text",
  mutedText: "--agent-muted",
  softText: "--agent-soft",
  accent: "--agent-accent",
  accentSoft: "--agent-accent-soft",
  danger: "--agent-danger",
  shadow: "--agent-shadow",
};

export function applyAgentTheme(theme: AgentSessionTheme): void {
  if (typeof document === "undefined") {
    return;
  }
  const root = document.documentElement;
  root.dataset.theme = theme.isDark ? "dark" : "light";
  root.dataset.codexWindowType = "electron";
  root.dataset.windowType = "electron";
  root.classList.toggle("dark", theme.isDark);
  root.classList.toggle("electron-dark", theme.isDark);
  root.classList.toggle("light", !theme.isDark);
  root.style.colorScheme = theme.isDark ? "dark" : "light";
  if (document.body) {
    document.body.dataset.codexWindowType = "electron";
  }
  for (const [key, variable] of Object.entries(cssVariables) as Array<
    [keyof AgentSessionTheme, string | null]
  >) {
    if (!variable) {
      continue;
    }
    root.style.setProperty(variable, String(theme[key]));
  }
}
