import { useEffect, type RefObject } from "react";
import { KEYMAP, MENU_KEYMAP, keyDispatchFor, type KeyAction } from "../keymap";
import type { CtrlJMode, OptionValue, SessionOption } from "../session";
import { isEditableTarget } from "./useTypeToFocus";
import { visibleChoices } from "../components/options";

function cycleOption(options: SessionOption[], ids: string[], setOption: (id: string, value: OptionValue) => void) {
  const opt = ids.includes("effort")
    ? options.find((o) => o.role === "effort")
    : ids.map((id) => options.find((o) => o.id === id)).find(Boolean);
  const choices = opt ? visibleChoices(opt) : [];
  if (!opt || opt.kind !== "select" || !choices.length || opt.disabled) return false;
  const i = choices.findIndex((c) => c.value === opt.value);
  const next = choices[(i + 1 + choices.length) % choices.length];
  if (!next) return false;
  setOption(opt.id, next.value);
  return true;
}

function togglePlan(options: SessionOption[], setOption: (id: string, value: OptionValue) => void) {
  const opt = options.find((o) => (o.id === "mode" || o.id === "permissionMode") && o.kind === "select" && o.choices?.some((c) => c.value === "plan"));
  if (!opt || opt.disabled) return false;
  const fallback = opt.choices?.some((c) => c.value === "build") ? "build" : "default";
  setOption(opt.id, opt.value === "plan" ? fallback : "plan");
  return true;
}

export function actionSupported(action: KeyAction, options: SessionOption[], running: boolean): boolean {
  if (action === "help") return true;
  if (action === "interrupt") return running;
  if (action === "cycle-mode") return Boolean(options.find((o) => ["permissionMode", "mode", "approvals"].includes(o.id) && o.kind === "select" && !o.disabled));
  if (action === "cycle-model" || action === "open-model") return Boolean(options.find((o) => o.id === "model" && o.kind === "select" && !o.disabled));
  if (action === "cycle-thinking") return Boolean(options.find((o) => o.role === "effort" && o.kind === "select" && visibleChoices(o).length && !o.disabled));
  if (action === "toggle-fast") return Boolean(options.find((o) => o.id === "fastMode" && o.kind === "toggle" && !o.disabled));
  if (action === "toggle-plan") return Boolean(options.find((o) => (o.id === "mode" || o.id === "permissionMode") && o.choices?.some((c) => c.value === "plan") && !o.disabled));
  return false;
}

export function useKeymap({
  options,
  setOption,
  running,
  stop,
  helpOpen,
  setHelpOpen,
  popupOpen,
  closePopup,
  ctrlJ,
  inputRef,
  openModel,
}: {
  options: SessionOption[];
  setOption: (id: string, value: OptionValue) => void;
  running: boolean;
  stop: () => void;
  helpOpen: boolean;
  setHelpOpen: (v: boolean) => void;
  popupOpen: boolean;
  closePopup: () => void;
  ctrlJ: CtrlJMode;
  inputRef: RefObject<HTMLTextAreaElement | null>;
  openModel: () => void;
}) {
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const dispatch = keyDispatchFor(e, { editable: isEditableTarget(e.target), popupOpen, ctrlJ });
      if (!dispatch) return;
      if (dispatch.kind === "menu") return;
      const action = dispatch.action;
      if (action === "help" && e.key === "?" && inputRef.current && inputRef.current.value.trim()) return;
      if (action === "interrupt") {
        if (helpOpen) {
          e.preventDefault();
          setHelpOpen(false);
          return;
        }
        if (popupOpen) {
          e.preventDefault();
          closePopup();
          return;
        }
        if (!running) return;
        e.preventDefault();
        stop();
        return;
      }
      e.preventDefault();
      if (action === "help") setHelpOpen(!helpOpen);
      else if (action === "cycle-mode") cycleOption(options, ["permissionMode", "mode", "approvals"], setOption);
      else if (action === "cycle-model") cycleOption(options, ["model"], setOption);
      else if (action === "open-model") openModel();
      else if (action === "cycle-thinking") cycleOption(options, ["effort"], setOption);
      else if (action === "toggle-fast") {
        const opt = options.find((o) => o.id === "fastMode" && o.kind === "toggle" && !o.disabled);
        if (opt) setOption(opt.id, !opt.value);
      } else if (action === "toggle-plan") {
        togglePlan(options, setOption);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [closePopup, ctrlJ, helpOpen, inputRef, openModel, options, popupOpen, running, setHelpOpen, setOption, stop]);
}

export function ShortcutOverlay({ provider, options, running, ctrlJ, onClose }: { provider: string; options: SessionOption[]; running: boolean; ctrlJ: CtrlJMode; onClose: () => void }) {
  const menuRows = MENU_KEYMAP.filter((k) => !k.ctrlJMode || k.ctrlJMode === ctrlJ);
  return (
    <div className="shortcut-backdrop" onMouseDown={onClose}>
      <div className="shortcut-panel" onMouseDown={(e) => e.stopPropagation()}>
        <div className="shortcut-title">{provider} shortcuts</div>
        {KEYMAP.map((k) => {
          const ok = actionSupported(k.action, options, running) || k.action === "interrupt";
          return (
            <div key={k.combo} className={"shortcut-row" + (ok ? "" : " disabled")}>
              <kbd>{k.combo}</kbd>
              <span>{k.description}</span>
            </div>
          );
        })}
        {menuRows.map((k) => (
          <div key={`${k.combo}:${k.action}`} className="shortcut-row">
            <kbd>{k.combo}</kbd>
            <span>{k.description}</span>
          </div>
        ))}
      </div>
    </div>
  );
}
