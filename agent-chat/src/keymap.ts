export type KeyAction =
  | "cycle-mode"
  | "cycle-model"
  | "open-model"
  | "cycle-thinking"
  | "toggle-fast"
  | "toggle-plan"
  | "interrupt"
  | "help";
export type MenuKeyAction = "menu-next" | "menu-prev" | "menu-accept" | "menu-close" | "newline" | "picker-rail-next" | "picker-rail-prev";

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
type KeyEventLike = Pick<KeyboardEvent, "key" | "ctrlKey" | "shiftKey" | "metaKey" | "altKey">;
export type KeyDispatch =
  | { kind: "global"; action: KeyAction }
  | { kind: "menu"; action: MenuKeyAction };

export const KEYMAP: KeymapEntry[] = [
  { combo: "Shift+Tab", description: "Cycle mode-like option", action: "cycle-mode" },
  { combo: "Ctrl+Shift+M", description: "Cycle model", action: "cycle-model" },
  { combo: "Ctrl+Shift+P", description: "Open model selector", action: "open-model" },
  { combo: "Ctrl+Shift+T", description: "Cycle thinking or effort", action: "cycle-thinking" },
  { combo: "Ctrl+Shift+F", description: "Toggle fast mode", action: "toggle-fast" },
  { combo: "Ctrl+Shift+L", description: "Toggle plan mode", action: "toggle-plan" },
  { combo: "Esc", description: "Interrupt or close overlay", action: "interrupt" },
  { combo: "Ctrl+/", description: "Toggle shortcut help", action: "help" },
  { combo: "?", description: "Toggle shortcut help when input is empty", action: "help" },
];

export const MENU_KEYMAP: MenuKeymapEntry[] = [
  { combo: "ArrowDown", description: "Next menu item", action: "menu-next" },
  { combo: "Ctrl+N", description: "Next menu item", action: "menu-next" },
  { combo: "Ctrl+J", description: "Next menu item while a menu is open", action: "menu-next" },
  { combo: "ArrowUp", description: "Previous menu item", action: "menu-prev" },
  { combo: "Ctrl+P", description: "Previous menu item while a menu is open", action: "menu-prev" },
  { combo: "Ctrl+K", description: "Previous menu item while a menu is open", action: "menu-prev" },
  { combo: "Enter", description: "Accept menu item", action: "menu-accept" },
  { combo: "Tab", description: "Accept menu item or switch picker search/rail", action: "menu-accept" },
  { combo: "ArrowRight", description: "Next harness in model picker rail", action: "picker-rail-next" },
  { combo: "ArrowLeft", description: "Previous harness in model picker rail", action: "picker-rail-prev" },
  { combo: "Esc", description: "Close menu", action: "menu-close" },
];

export function actionForKey(e: KeyEventLike): KeyAction | null {
  if (e.metaKey || e.altKey) return null;
  return KEYMAP.find((entry) => comboMatches(entry.combo, e))?.action ?? null;
}

export function menuActionForKey(e: KeyEventLike): MenuKeyAction | null {
  if (e.metaKey || e.altKey) return null;
  const entry = MENU_KEYMAP.find((item) => comboMatches(item.combo, e));
  return entry?.action ?? null;
}

export function keyDispatchFor(e: KeyEventLike, ctx: { editable: boolean; popupOpen: boolean }): KeyDispatch | null {
  const menuAction = menuActionForKey(e);
  if (ctx.popupOpen && menuAction) return { kind: "menu", action: menuAction };
  if (ctx.editable && !ctx.popupOpen && isPlainCtrlLetter(e)) return null;
  const action = actionForKey(e);
  if (!action) return null;
  if (ctx.popupOpen && action !== "interrupt") return null;
  return { kind: "global", action };
}

function isPlainCtrlLetter(e: KeyEventLike): boolean {
  return e.ctrlKey && !e.shiftKey && !e.metaKey && !e.altKey && /^[a-z]$/i.test(e.key);
}

function comboMatches(combo: string, e: KeyEventLike): boolean {
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
  if (key === "ArrowRight") return e.key === "ArrowRight";
  if (key === "ArrowLeft") return e.key === "ArrowLeft";
  if (key === "?") return e.key === "?";
  if (key === "/") return e.key === "/";
  return e.key.toLowerCase() === key.toLowerCase();
}
