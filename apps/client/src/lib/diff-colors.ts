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

const lightAdditionLineBackground = "#dafbe1";
const lightDeletionLineBackground = "#ffebe9";
const darkAdditionLineBackground = "#2ea04326";
const darkDeletionLineBackground = "#f851491a";

export const diffColors: Record<"light" | "dark", DiffColorPalette> = {
  light: {
    addition: {
      lineBackground: lightAdditionLineBackground,
      gutterBackground: "#b8f0c8",
      textBackground: lightAdditionLineBackground,
      lineNumberForeground: "#116329",
    },
    deletion: {
      lineBackground: lightDeletionLineBackground,
      gutterBackground: "#ffdcd7",
      textBackground: lightDeletionLineBackground,
      lineNumberForeground: "#a0111f",
    },
    collapsed: {
      background: "#E9F4FF",
      foreground: "#4b5563",
    },
  },
  dark: {
    addition: {
      lineBackground: darkAdditionLineBackground,
      gutterBackground: "#3fb9504d",
      textBackground: darkAdditionLineBackground,
      lineNumberForeground: "#7ee787",
    },
    deletion: {
      lineBackground: darkDeletionLineBackground,
      gutterBackground: "#f851494d",
      textBackground: darkDeletionLineBackground,
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
