export type KeyAction =
  | "cycle-mode"
  | "cycle-model"
  | "open-model"
  | "cycle-thinking"
  | "toggle-fast"
  | "toggle-plan"
  | "interrupt"
  | "help";

export interface KeymapEntry {
  combo: string;
  description: string;
  action: KeyAction;
}

export const KEYMAP: KeymapEntry[] = [
  { combo: "Shift+Tab", description: "Cycle mode-like option", action: "cycle-mode" },
  { combo: "Ctrl+P", description: "Cycle model", action: "cycle-model" },
  { combo: "Ctrl+Shift+P", description: "Open model selector", action: "open-model" },
  { combo: "Ctrl+T", description: "Cycle thinking or effort", action: "cycle-thinking" },
  { combo: "Ctrl+F", description: "Toggle fast mode", action: "toggle-fast" },
  { combo: "Ctrl+Shift+M", description: "Toggle plan mode", action: "toggle-plan" },
  { combo: "Esc", description: "Interrupt or close overlay", action: "interrupt" },
  { combo: "Ctrl+/", description: "Toggle shortcut help", action: "help" },
  { combo: "?", description: "Toggle shortcut help when input is empty", action: "help" },
];

export function actionForKey(e: KeyboardEvent): KeyAction | null {
  if (e.metaKey || e.altKey) return null;
  return KEYMAP.find((entry) => comboMatches(entry.combo, e))?.action ?? null;
}

function comboMatches(combo: string, e: KeyboardEvent): boolean {
  const parts = combo.split("+");
  const key = parts[parts.length - 1];
  const wantsCtrl = parts.includes("Ctrl");
  const wantsShift = parts.includes("Shift");
  if (e.ctrlKey !== wantsCtrl) return false;
  if (key !== "?" && e.shiftKey !== wantsShift) return false;
  if (key === "Esc") return e.key === "Escape";
  if (key === "Tab") return e.key === "Tab";
  if (key === "?") return e.key === "?";
  if (key === "/") return e.key === "/";
  return e.key.toLowerCase() === key.toLowerCase();
}
