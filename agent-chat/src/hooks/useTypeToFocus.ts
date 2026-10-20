import { useEffect } from "react";

export function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName.toLowerCase();
  return tag === "textarea" || tag === "input" || tag === "select" || target.isContentEditable;
}

function primaryTextarea(): HTMLTextAreaElement | null {
  return document.querySelector<HTMLTextAreaElement>("[data-primary-textarea='true']");
}

export function anyAgentPopupOpen(): boolean {
  return Boolean(document.querySelector("[data-agent-popup='true']"));
}

export function useTypeToFocus() {
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.isComposing || isEditableTarget(e.target) || e.defaultPrevented) return;
      if (anyAgentPopupOpen()) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key.length !== 1) return;
      primaryTextarea()?.focus();
    };
    const onPaste = (e: ClipboardEvent) => {
      if (isEditableTarget(e.target) || e.defaultPrevented) return;
      if (anyAgentPopupOpen()) return;
      primaryTextarea()?.focus();
    };
    window.addEventListener("keydown", onKeyDown, true);
    window.addEventListener("paste", onPaste, true);
    return () => {
      window.removeEventListener("keydown", onKeyDown, true);
      window.removeEventListener("paste", onPaste, true);
    };
  }, []);
}
