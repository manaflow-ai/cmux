export type DiffTone = {
  lineBackground: string;
  gutterBackground: string;
  textBackground: string;
  lineNumberForeground: string;
};

export type DiffCollapsedPalette = {
  background: string;
  foreground: string;
};

export type DiffColorPalette = {
  addition: DiffTone;
  deletion: DiffTone;
  collapsed: DiffCollapsedPalette;
};

export const diffColors: Record<"light" | "dark", DiffColorPalette> = {
  light: {
    addition: {
      lineBackground: "#dafbe1",
      gutterBackground: "#b8f0c8",
      textBackground: "#dafbe1",
      lineNumberForeground: "#116329",
    },
    deletion: {
      lineBackground: "#ffebe9",
      gutterBackground: "#ffdcd7",
      textBackground: "#ffebe9",
      lineNumberForeground: "#a0111f",
    },
    collapsed: {
      background: "#E9F4FF",
      foreground: "#4b5563",
    },
  },
  dark: {
    addition: {
      lineBackground: "#2ea04326",
      gutterBackground: "#3fb9504d",
      textBackground: "#2ea04366",
      lineNumberForeground: "#7ee787",
    },
    deletion: {
      lineBackground: "#f851491a",
      gutterBackground: "#f851494d",
      textBackground: "#f8514966",
      lineNumberForeground: "#ff7b72",
    },
    collapsed: {
      background: "#1f2733",
      foreground: "#e5e7eb",
    },
  },
};

export function getDiffColorPalette(theme: "light" | "dark") {
  return diffColors[theme];
}
