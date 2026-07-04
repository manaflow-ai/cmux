export type KeyAction =
  | "cycle-mode"
  | "cycle-model"
  | "open-model"
  | "cycle-thinking"
  | "toggle-fast"
  | "toggle-plan"
  | "interrupt"
  | "help";
export type MenuKeyAction = "menu-next" | "menu-prev" | "menu-accept" | "menu-close" | "newline";

export interface KeymapEntry {
  combo: string;
  description: string;
  action: KeyAction;
}
export interface MenuKeymapEntry {
  combo: string;
  description: string;
  action: MenuKeyAction;
  ctrlJMode?: "newline" | "menu";
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

export const MENU_KEYMAP: MenuKeymapEntry[] = [
  { combo: "ArrowDown", description: "Next menu item", action: "menu-next" },
  { combo: "Ctrl+N", description: "Next menu item", action: "menu-next" },
  { combo: "ArrowUp", description: "Previous menu item", action: "menu-prev" },
  { combo: "Ctrl+P", description: "Previous menu item while a menu is open", action: "menu-prev" },
  { combo: "Enter", description: "Accept menu item", action: "menu-accept" },
  { combo: "Tab", description: "Accept menu item", action: "menu-accept" },
  { combo: "Esc", description: "Close menu", action: "menu-close" },
  { combo: "Ctrl+J", description: "Insert newline", action: "newline", ctrlJMode: "newline" },
  { combo: "Ctrl+J", description: "Next menu item while a menu is open", action: "menu-next", ctrlJMode: "menu" },
];

export function actionForKey(e: KeyboardEvent): KeyAction | null {
  if (e.metaKey || e.altKey) return null;
  return KEYMAP.find((entry) => comboMatches(entry.combo, e))?.action ?? null;
}

export function menuActionForKey(e: Pick<KeyboardEvent, "key" | "ctrlKey" | "shiftKey" | "metaKey" | "altKey">, ctrlJMode: "newline" | "menu"): MenuKeyAction | null {
  if (e.metaKey || e.altKey) return null;
  const entry = MENU_KEYMAP.find((item) =>
    (!item.ctrlJMode || item.ctrlJMode === ctrlJMode) && comboMatches(item.combo, e),
  );
  return entry?.action ?? null;
}

function comboMatches(combo: string, e: Pick<KeyboardEvent, "key" | "ctrlKey" | "shiftKey" | "metaKey" | "altKey">): boolean {
  const parts = combo.split("+");
  const key = parts[parts.length - 1];
  const wantsCtrl = parts.includes("Ctrl");
  const wantsShift = parts.includes("Shift");
  if (e.ctrlKey !== wantsCtrl) return false;
  if (key !== "?" && e.shiftKey !== wantsShift) return false;
  if (key === "Esc") return e.key === "Escape";
  if (key === "Tab") return e.key === "Tab";
  if (key === "Enter") return e.key === "Enter";
  if (key === "ArrowDown") return e.key === "ArrowDown";
  if (key === "ArrowUp") return e.key === "ArrowUp";
  if (key === "?") return e.key === "?";
  if (key === "/") return e.key === "/";
  return e.key.toLowerCase() === key.toLowerCase();
}
