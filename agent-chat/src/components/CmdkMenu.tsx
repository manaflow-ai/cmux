import { Popover } from "@base-ui-components/react/popover";
import { Command } from "cmdk";
import { useLayoutEffect, useRef, type ReactElement, type ReactNode, type RefObject } from "react";
import { menuActionForKey } from "../keymap";
import { Check, SearchIcon } from "./icons";

export interface CmdkItem {
  id: string;
  label: string;
  description?: string;
  disabled?: boolean;
  selected?: boolean;
  icon?: ReactNode;
  value?: string;
  onSelect(): void;
}

export interface CmdkGroup {
  id: string;
  label?: string;
  icon?: ReactNode;
  items: CmdkItem[];
}

function useSelectedItemAutoscroll(ref: RefObject<HTMLElement | null>, active: boolean) {
  useLayoutEffect(() => {
    const root = ref.current;
    if (!root || !active) return;
    const scroll = () => {
      root.querySelector<HTMLElement>('[data-selected="true"]')?.scrollIntoView({ block: "nearest" });
    };
    scroll();
    const obs = new MutationObserver(scroll);
    obs.observe(root, { subtree: true, attributes: true, attributeFilter: ["data-selected"] });
    return () => obs.disconnect();
  }, [active, ref]);
}

export function CmdkMenu({
  groups,
  open,
  onOpenChange,
  trigger,
  className = "",
  inline = false,
}: {
  groups: CmdkGroup[];
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  trigger?: ReactElement<Record<string, unknown>>;
  className?: string;
  inline?: boolean;
}) {
  const count = groups.reduce((n, g) => n + g.items.length, 0);
  const listRef = useRef<HTMLDivElement>(null);
  useSelectedItemAutoscroll(listRef, true);
  const content = (
    <Command
      className={`cmdk menu ${className}`}
      data-agent-popup="true"
      loop
      onKeyDown={(e) => {
        const action = menuActionForKey(e.nativeEvent);
        if ((action === "menu-next" || action === "menu-prev") && e.ctrlKey) {
          e.preventDefault();
          e.currentTarget.dispatchEvent(new KeyboardEvent("keydown", {
            key: action === "menu-next" ? "ArrowDown" : "ArrowUp",
            bubbles: true,
          }));
        } else if (action === "menu-close") {
          e.preventDefault();
          onOpenChange?.(false);
        }
      }}
    >
      {count > 8 ? (
        <div className="cmdk-search">
          <SearchIcon />
          <Command.Input className="cmdk-input" placeholder="Search..." autoFocus />
        </div>
      ) : null}
      <Command.List ref={listRef} className="cmdk-list">
        <Command.Empty className="cmdk-empty">No matches</Command.Empty>
        {count ? groups.map((group) => (
          <Command.Group
            key={group.id}
            className="cmdk-group"
            heading={group.label ? (
              <div className="cmdk-heading">
                {group.icon}
                <span>{group.label}</span>
              </div>
            ) : undefined}
          >
            {group.items.map((item) => (
              <Command.Item
                key={item.id}
                value={item.value ?? `${group.label ?? ""} ${item.label} ${item.description ?? ""}`}
                disabled={item.disabled}
                className="menu-item cmdk-item"
                onSelect={() => {
                  item.onSelect();
                  if (!inline) onOpenChange?.(false);
                }}
              >
                {item.icon ? <span className="menu-choice-icon">{item.icon}</span> : null}
                <span className="cmdk-item-main">
                  <span className="cmdk-item-label">{item.label}</span>
                  {item.description ? <span className="cmd-desc">{item.description}</span> : null}
                </span>
                {item.selected ? <span className="mi-check selected"><Check /></span> : null}
              </Command.Item>
            ))}
          </Command.Group>
        )) : null}
      </Command.List>
    </Command>
  );
  if (inline) return content;
  return (
    <Popover.Root open={open} onOpenChange={onOpenChange}>
      {trigger ? <Popover.Trigger render={trigger} /> : null}
      <Popover.Portal>
        <Popover.Positioner className="select-positioner" sideOffset={8} align="start">
          <Popover.Popup data-agent-popup="true">{content}</Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}
