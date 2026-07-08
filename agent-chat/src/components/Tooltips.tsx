import { Tooltip } from "@base-ui-components/react/tooltip";
import type { ReactElement } from "react";
import { KEYMAP, type KeyAction } from "../keymap";

function comboForAction(action?: KeyAction): string {
  if (!action) return "";
  return KEYMAP.find((k) => k.action === action)?.combo ?? "";
}

function comboGlyph(combo: string): string {
  return combo
    .replaceAll("Ctrl", "⌃")
    .replaceAll("Shift", "⇧")
    .replaceAll("Tab", "⇥")
    .replaceAll("+", "");
}

export function HintTooltip({ label, action, children }: { label: string; action?: KeyAction; children: ReactElement<Record<string, unknown>> }) {
  const combo = comboForAction(action);
  return (
    <Tooltip.Root>
      <Tooltip.Trigger render={children} />
      <Tooltip.Portal>
        <Tooltip.Positioner sideOffset={7}>
          <Tooltip.Popup className="tooltip">
            <span>{label}</span>
            {combo ? <kbd>{comboGlyph(combo)}</kbd> : null}
          </Tooltip.Popup>
        </Tooltip.Positioner>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}
