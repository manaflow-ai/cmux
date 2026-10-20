import { keyDispatchFor } from "../src/keymap";

function key(key: string, init: Partial<Pick<KeyboardEvent, "ctrlKey" | "shiftKey" | "metaKey" | "altKey">> = {}) {
  return {
    key,
    ctrlKey: init.ctrlKey ?? false,
    shiftKey: init.shiftKey ?? false,
    metaKey: init.metaKey ?? false,
    altKey: init.altKey ?? false,
  };
}

const nativeCtrlK = keyDispatchFor(key("k", { ctrlKey: true }), { editable: true, popupOpen: false });
if (nativeCtrlK !== null) {
  throw new Error(`editable Ctrl+K should pass through, got ${JSON.stringify(nativeCtrlK)}`);
}

const popupNext = keyDispatchFor(key("n", { ctrlKey: true }), { editable: true, popupOpen: true });
if (popupNext?.kind !== "menu" || popupNext.action !== "menu-next") {
  throw new Error(`popup Ctrl+N should navigate menu, got ${JSON.stringify(popupNext)}`);
}

const shiftedEffort = keyDispatchFor(key("t", { ctrlKey: true, shiftKey: true }), { editable: true, popupOpen: false });
if (shiftedEffort?.kind !== "global" || shiftedEffort.action !== "cycle-thinking") {
  throw new Error(`editable Ctrl+Shift+T should cycle effort, got ${JSON.stringify(shiftedEffort)}`);
}

console.log("keymap dispatch assertions passed");
