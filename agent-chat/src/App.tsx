import { createContext, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactElement, type ReactNode, type RefObject } from "react";
import { Popover } from "@base-ui-components/react/popover";
import { Tooltip } from "@base-ui-components/react/tooltip";
import { Command } from "cmdk";
import {
  useSession,
  type Block,
  type CommandEntry,
  type CommandGroup,
  type OptionValue,
  type CtrlJMode,
  type Provider,
  type SessionActions,
  type SessionOption,
  type SessionState,
} from "./session";
import { renderMd } from "./md";
import { KEYMAP, MENU_KEYMAP, actionForKey, menuActionForKey, type KeyAction } from "./keymap";

// One WebSocket-backed session state, created once in App and shared.
const Ctx = createContext<SessionState | null>(null);
const useCtx = () => useContext(Ctx)!;

const PROVIDER_COLOR: Record<string, string> = {
  claude: "#d97757", codex: "#10a37f", opencode: "#f2a600", pi: "#8b7cff", gemini: "#4285f4",
};
function colorFor(id: string): string {
  if (PROVIDER_COLOR[id]) return PROVIDER_COLOR[id];
  let h = 0;
  for (const c of id) h = (h * 31 + c.charCodeAt(0)) % 360;
  return `hsl(${h} 60% 60%)`;
}
function basename(p: string): string {
  const t = String(p || "").replace(/\/+$/, "");
  return t.split("/").pop() || t || "~";
}

function Dot({ id }: { id: string }) {
  return <span className="dot" style={{ background: colorFor(id), color: colorFor(id) }} />;
}

function themeIsDark(): boolean {
  const bg = getComputedStyle(document.documentElement).getPropertyValue("--bg").trim();
  const m = bg.match(/^#([0-9a-f]{6})$/i);
  if (!m) return true;
  const n = parseInt(m[1], 16);
  const r = (n >> 16) & 255;
  const g = (n >> 8) & 255;
  const b = n & 255;
  return (r * 299 + g * 587 + b * 114) / 1000 < 150;
}

function DrawnProviderIcon({ id }: { id: string }) {
  const color = colorFor(id);
  if (id === "claude") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <path d="M8 1.7v12.6M1.7 8h12.6M3.5 3.5l9 9M12.5 3.5l-9 9" fill="none" stroke="currentColor" strokeWidth="1.45" strokeLinecap="round" />
      </svg>
    );
  }
  if (id === "codex") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <path d="M8 1.8l4.9 2.8v5.7L8 13.2l-4.9-2.9V4.6L8 1.8zm0 0v4.1m4.9-1.3L9.3 6.7m-6.2-2.1l3.6 2.1m-3.6 3.6l3.6-2.1m6.2 2.1L9.3 8.2M8 13.2V9.1" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  }
  if (id === "opencode") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <rect x="2.2" y="3" width="11.6" height="10" rx="2" fill="none" stroke="currentColor" strokeWidth="1.25" />
        <path d="M4.6 6.1l2 1.9-2 1.9M7.9 10.1h3.1" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  }
  if (id === "pi") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <text x="8" y="11.8" textAnchor="middle" fontSize="13" fontWeight="650" fill="currentColor">π</text>
      </svg>
    );
  }
  if (id === "gemini") {
    return (
      <svg className="provider-icon" viewBox="0 0 16 16" style={{ color }}>
        <path d="M8 1.8c.7 3.1 2.1 4.5 5.2 5.2C10.1 7.7 8.7 9.1 8 12.2 7.3 9.1 5.9 7.7 2.8 7 5.9 6.3 7.3 4.9 8 1.8z" fill="currentColor" />
      </svg>
    );
  }
  return <Dot id={id} />;
}

function ProviderIcon({ provider }: { provider: Provider }) {
  const src = themeIsDark() ? (provider.iconDarkUrl ?? provider.iconUrl) : provider.iconUrl;
  if (!src) return <DrawnProviderIcon id={provider.id} />;
  return (
    <span className="provider-icon-img" aria-hidden="true" style={{ backgroundImage: `url(${src})` }} />
  );
}

const ArrowUp = () => (
  <svg viewBox="0 0 16 16" width="16" height="16"><path d="M8 13V3.5M4 7l4-4 4 4" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
const Chevron = () => (
  <svg viewBox="0 0 10 6" width="10" height="6"><path d="M1 1l4 4 4-4" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
const Check = () => (
  <svg viewBox="0 0 12 12" width="12" height="12"><path d="M2.5 6.2l2.3 2.3L9.5 3.5" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
const FolderIcon = () => (
  <svg viewBox="0 0 14 12" width="13" height="11" fill="none" stroke="currentColor" strokeWidth="1.2"><path d="M1 3.4c0-.7.5-1.3 1.2-1.3h2.5l1.2 1.4h5.7c.7 0 1.2.6 1.2 1.3v4.9c0 .7-.5 1.3-1.2 1.3H2.2C1.5 11 1 10.4 1 9.7z" /></svg>
);
const SparkIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8 2v12M2 8h12M3.8 3.8l8.4 8.4M12.2 3.8l-8.4 8.4" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" /></svg>
);
const BoltIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8.8 1.8L3.9 8.7h3.6l-.5 5.5 5.1-7.1H8.4l.4-5.3z" fill="currentColor" /></svg>
);
function BarsIcon({ filled = 4, bars = 4 }: { filled?: number; bars?: number }) {
  const count = Math.max(1, bars);
  const active = Math.max(0, Math.min(count, filled));
  return (
    <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true">
      {Array.from({ length: count }, (_, i) => {
        const x = 3 + (i * 10) / Math.max(1, count - 1);
        const h = 2.2 + (i * 8.2) / Math.max(1, count - 1);
        return (
          <path
            key={i}
            d={`M${x.toFixed(1)} 12V${(12 - h).toFixed(1)}`}
            fill="none"
            stroke="currentColor"
            strokeWidth="1.7"
            strokeLinecap="round"
            opacity={i < active ? 1 : 0.35}
          />
        );
      })}
    </svg>
  );
}
const PlanIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M2.5 4.3l3.4-1.5 4.2 1.5 3.4-1.5v8.9l-3.4 1.5-4.2-1.5-3.4 1.5V4.3zM5.9 2.8v8.9M10.1 4.3v8.9" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
const ShieldIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8 2.2l4.7 1.7v3.6c0 3.1-1.9 5.3-4.7 6.3-2.8-1-4.7-3.2-4.7-6.3V3.9L8 2.2z" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round" /><path d="M5.8 7.9l1.4 1.4 3-3.1" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
const EllipsisIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M3.5 8h.1M8 8h.1M12.5 8h.1" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" /></svg>
);
const CopyIcon = () => (
  <svg viewBox="0 0 16 16" width="14" height="14"><path d="M5.2 5.2h7.1v7.1H5.2zM3.7 10.8H3V3.7h7.1v.7" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round" /></svg>
);

function useAutoGrow(value: string, max: number) {
  const ref = useRef<HTMLTextAreaElement>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = Math.min(el.scrollHeight, max) + "px";
  }, [value, max]);
  return ref;
}

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

function HintTooltip({ label, action, children }: { label: string; action?: KeyAction; children: ReactElement }) {
  const combo = comboForAction(action);
  return (
    <Tooltip.Root>
      <Tooltip.Trigger delay={450} render={children} />
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

interface CmdkItem {
  id: string;
  label: string;
  description?: string;
  disabled?: boolean;
  selected?: boolean;
  icon?: ReactNode;
  value?: string;
  onSelect(): void;
}
interface CmdkGroup {
  id: string;
  label?: string;
  icon?: ReactNode;
  items: CmdkItem[];
}

function CmdkMenu({
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
  trigger?: ReactElement;
  className?: string;
  inline?: boolean;
}) {
  const count = groups.reduce((n, g) => n + g.items.length, 0);
  const content = (
    <Command
      className={`cmdk menu ${className}`}
      loop
      onKeyDown={(e) => {
        if (e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey && (e.key.toLowerCase() === "n" || e.key.toLowerCase() === "p")) {
          e.preventDefault();
          e.currentTarget.dispatchEvent(new KeyboardEvent("keydown", {
            key: e.key.toLowerCase() === "n" ? "ArrowDown" : "ArrowUp",
            bubbles: true,
          }));
        } else if (e.key === "Escape") {
          onOpenChange?.(false);
        }
      }}
    >
      {count > 8 ? <Command.Input className="cmdk-input" placeholder="Search…" autoFocus /> : null}
      <Command.List className="cmdk-list">
        <Command.Empty className="cmdk-empty">No matches</Command.Empty>
        {groups.map((group) => (
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
        ))}
      </Command.List>
    </Command>
  );
  if (inline) return content;
  return (
    <Popover.Root open={open} onOpenChange={onOpenChange}>
      {trigger ? <Popover.Trigger render={trigger} /> : null}
      <Popover.Portal>
        <Popover.Positioner className="select-positioner" sideOffset={8} align="start">
          <Popover.Popup>{content}</Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function CwdPopover({ cwd, onChange, onCommit }: { cwd: string; onChange: (v: string) => void; onCommit: (v: string) => void }) {
  return (
    <Popover.Root onOpenChange={(open) => { if (!open) onCommit(cwd); }}>
      <HintTooltip label="Change working directory">
        <Popover.Trigger className="row-control cwd-trigger">
          <FolderIcon />
          <span className="cwd-label">{basename(cwd)}</span>
        </Popover.Trigger>
      </HintTooltip>
      <Popover.Portal>
        <Popover.Positioner sideOffset={8} align="start">
          <Popover.Popup className="popover">
            <div className="popover-label">Working directory</div>
            <input
              className="cwd-edit"
              spellCheck={false}
              value={cwd}
              autoFocus
              onChange={(e) => onChange(e.target.value)}
              onBlur={(e) => onCommit(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  onCommit((e.target as HTMLInputElement).value);
                  (e.target as HTMLInputElement).blur();
                }
              }}
            />
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function currentChoice(option?: SessionOption) {
  if (!option) return null;
  const value = String(option.value ?? "");
  return option.choices?.find((c) => c.value === value) ?? (value ? { value, label: value } : null);
}

function isOffLikeValue(value: string): boolean {
  return /^(off|none|no[-_ ]?reasoning)$/i.test(value);
}

function visibleChoices(option: SessionOption) {
  const choices = option.choices ?? [];
  return option.role === "effort" ? choices.filter((c) => !isOffLikeValue(c.value)) : choices;
}

function effortFill(option: SessionOption, value: OptionValue = option.value, bars = 4): number {
  const choices = visibleChoices(option);
  const count = choices.length || 1;
  const index = Math.max(0, choices.findIndex((c) => c.value === value));
  return Math.max(1, Math.round(((index + 1) / count) * bars));
}

function prettyValue(option?: SessionOption): string {
  const choice = currentChoice(option);
  if (!choice) return "";
  const raw = String(choice.value ?? "");
  const label = String(choice.label ?? raw);
  if (label && label !== raw) return label;
  if (/^x/i.test(raw) || raw === "max") return "Extra high";
  return raw
    .replace(/[-_]+/g, " ")
    .replace(/([a-z])([A-Z])/g, "$1 $2")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function optionAction(id: string): KeyAction | undefined {
  if (id === "model") return "open-model";
  if (id === "effort" || id === "thinking") return "cycle-thinking";
  if (id === "fastMode") return "toggle-fast";
  if (id === "mode" || id === "permissionMode") return "cycle-mode";
  return undefined;
}

function optionTooltip(option: SessionOption): string {
  if (option.id === "model") return "Adjust model";
  if (option.id === "context") return "Adjust context window";
  if (option.id === "effort") return "Adjust effort level";
  if (option.id === "thinking") return "Adjust thinking level";
  if (option.id === "fastMode") return "Toggle fast mode";
  if (option.id === "mode" || option.id === "permissionMode") return "Change mode";
  return `Adjust ${option.label}`;
}

function InlineSelect({
  option,
  icon,
  choiceIcon,
  label,
  onChange,
  open,
  onOpenChange,
}: {
  option: SessionOption;
  icon: ReactNode;
  choiceIcon?: (value: string) => ReactNode;
  label: string;
  onChange: (id: string, value: OptionValue) => void;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const value = String(option.value ?? "");
  const visible = visibleChoices(option);
  const choices = visible.length
    ? visible
    : (value ? [{ value, label: value }] : []);
  const current = choices.find((c) => c.value === value)?.label ?? (value || option.label);
  const trigger = (
    <button type="button" className="row-control row-select select-trigger" aria-label={option.label} disabled={option.disabled || !choices.length}>
      <span className="row-icon">{icon}</span>
      <span className="row-value">{label || current}</span>
    </button>
  );
  return (
    <HintTooltip label={optionTooltip(option)} action={optionAction(option.id)}>
      <span>
        <CmdkMenu
          open={open}
          onOpenChange={onOpenChange}
          trigger={trigger}
          className="option-menu"
          groups={[{
            id: option.id,
            items: choices.map((c) => ({
              id: c.value,
              label: c.label,
              description: c.description,
              icon: choiceIcon?.(c.value),
              selected: c.value === option.value,
              onSelect: () => onChange(option.id, String(c.value)),
            })),
          }]}
        />
      </span>
    </HintTooltip>
  );
}

function cycleSelect(option: SessionOption, onChange: (id: string, value: OptionValue) => void) {
  const choices = visibleChoices(option);
  if (option.kind !== "select" || !choices.length || option.disabled) return;
  const i = choices.findIndex((c) => c.value === option.value);
  const next = choices[(i + 1 + choices.length) % choices.length];
  if (next) onChange(option.id, next.value);
}

const INLINE_OPTION_IDS = new Set(["model", "context", "fastMode", "mode", "permissionMode"]);

function isInlineOption(option: SessionOption): boolean {
  return INLINE_OPTION_IDS.has(option.id) || option.role === "effort" || option.role === "approval";
}

function OverflowMenu({ options, onChange }: { options: SessionOption[]; onChange: (id: string, value: OptionValue) => void }) {
  if (!options.length) return null;
  const groups: CmdkGroup[] = options.map((option) => ({
    id: option.id,
    label: option.label,
    items: option.kind === "toggle"
      ? [{
          id: `${option.id}:toggle`,
          label: option.label,
          description: option.value ? "Currently on" : "Currently off",
          selected: Boolean(option.value),
          disabled: option.disabled,
          onSelect: () => onChange(option.id, !option.value),
        }]
      : (option.choices ?? []).map((choice) => ({
          id: `${option.id}:${choice.value}`,
          label: choice.label,
          description: choice.description,
          selected: choice.value === option.value,
          disabled: option.disabled,
          onSelect: () => onChange(option.id, choice.value),
        })),
  }));
  return (
    <Popover.Root>
      <HintTooltip label="More options">
        <Popover.Trigger className="row-control row-icon-only" aria-label="More options">
          <EllipsisIcon />
        </Popover.Trigger>
      </HintTooltip>
      <Popover.Portal>
        <Popover.Positioner sideOffset={8} align="end">
          <Popover.Popup className="overflow-menu menu">
            <CmdkMenu groups={groups} inline />
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function StaticProvider({ provider }: { provider: Provider }) {
  return (
    <HintTooltip label="Provider">
      <span className="row-control static-provider">
        <ProviderIcon provider={provider} />
        <span className="row-value">{provider.label}</span>
      </span>
    </HintTooltip>
  );
}

function StaticCwd({ cwd }: { cwd: string }) {
  return (
    <HintTooltip label="Working directory">
      <span className="row-control cwd-trigger">
        <FolderIcon />
        <span className="cwd-label">{basename(cwd)}</span>
      </span>
    </HintTooltip>
  );
}

function modelOption(options: SessionOption[]): SessionOption | undefined {
  return options.find((o) => o.id === "model" && o.kind === "select");
}

function HarnessModelPicker({
  provider,
  providers,
  options,
  allProviderOptions,
  open,
  onOpenChange,
  onSelect,
}: {
  provider: string;
  providers: Provider[];
  options: SessionOption[];
  allProviderOptions: Record<string, SessionOption[]>;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSelect: (provider: string, model: string) => void;
}) {
  const installed = providers.filter((p) => p.installed !== false);
  const missing = providers.filter((p) => p.installed === false);
  const currentProvider = providers.find((p) => p.id === provider) ?? { id: provider, label: provider };
  const currentModel = modelOption(options);
  const label = currentChoice(currentModel)?.label ?? String(currentModel?.value || currentProvider.label);
  const groups: CmdkGroup[] = installed.map((p) => {
    const opts = p.id === provider ? options : (allProviderOptions[p.id] ?? []);
    const model = modelOption(opts);
    const choices = model?.choices?.length ? model.choices : [];
    const items = choices.length
      ? choices.map((choice) => ({
          id: `${p.id}:${choice.value}`,
          label: choice.label,
          description: choice.description,
          icon: <ProviderIcon provider={p} />,
          selected: p.id === provider && choice.value === model?.value,
          value: `${p.label} ${choice.label} ${choice.value}`,
          onSelect: () => onSelect(p.id, choice.value),
        }))
      : [{
          id: `${p.id}:default`,
          label: "Default",
          description: "Model loads at start",
          icon: <ProviderIcon provider={p} />,
          selected: p.id === provider && !model?.value,
          value: `${p.label} default`,
          onSelect: () => onSelect(p.id, ""),
        }];
    return {
      id: p.id,
      label: p.label,
      icon: <ProviderIcon provider={p} />,
      items,
    };
  });
  if (missing.length) {
    groups.push({
      id: "not-installed",
      label: "Not installed",
      items: missing.map((p) => ({
        id: `missing:${p.id}`,
        label: p.label,
        description: p.installCommand,
        icon: <ProviderIcon provider={p} />,
        value: `${p.label} ${p.installCommand ?? ""}`,
        onSelect: () => {
          if (p.installCommand) navigator.clipboard?.writeText(p.installCommand).catch(() => {});
        },
      })),
    });
  }
  const trigger = (
    <button type="button" className="row-control provider-model-trigger select-trigger" aria-label="Switch harness or model">
      <ProviderIcon provider={currentProvider} />
      <span className="row-value">{label}</span>
      <span className="chev"><Chevron /></span>
    </button>
  );
  return (
    <HintTooltip label="Switch harness or model" action="open-model">
      <span>
        <CmdkMenu
          open={open}
          onOpenChange={onOpenChange}
          trigger={trigger}
          className="model-picker-menu"
          groups={groups}
        />
      </span>
    </HintTooltip>
  );
}

function StatusRow({
  provider,
  providers,
  allProviderOptions,
  onProviderModelChange,
  cwd,
  onCwdChange,
  onCwdCommit,
  options,
  onChange,
  openOptionId,
  setOpenOptionId,
  trailing,
}: {
  provider: string;
  providers?: Provider[];
  allProviderOptions?: Record<string, SessionOption[]>;
  onProviderModelChange?: (provider: string, model: string) => void;
  cwd: string;
  onCwdChange?: (v: string) => void;
  onCwdCommit?: (v: string) => void;
  options: SessionOption[];
  onChange: (id: string, value: OptionValue) => void;
  openOptionId: string | null;
  setOpenOptionId: (id: string | null) => void;
  trailing?: ReactNode;
}) {
  const effortLike = options.filter((o) => o.role === "effort" && o.kind === "select" && !isOffLikeValue(String(o.value)));
  const context = options.find((o) => o.id === "context" && o.kind === "select");
  const fast = options.find((o) => o.id === "fastMode" && o.kind === "toggle");
  const approval = options.find((o) => o.role === "approval" && o.kind === "toggle");
  const mode = options.find((o) => (o.id === "mode" || o.id === "permissionMode") && o.kind === "select");
  const overflow = options.filter((o) => !isInlineOption(o));
  const modeLabel = mode && !["", "default", "build"].includes(String(mode.value)) ? prettyValue(mode) : "";
  const providerInfo = providers?.find((p) => p.id === provider) ?? { id: provider, label: provider };
  return (
    <div className="status-row">
      {providers && onProviderModelChange
        ? (
          <HarnessModelPicker
            provider={provider}
            providers={providers}
            options={options}
            allProviderOptions={allProviderOptions ?? {}}
            open={openOptionId === "modelPicker"}
            onOpenChange={(open) => setOpenOptionId(open ? "modelPicker" : null)}
            onSelect={onProviderModelChange}
          />
        )
        : <StaticProvider provider={providerInfo} />}
      {fast ? (
        <HintTooltip label={optionTooltip(fast)} action="toggle-fast">
          <button
            type="button"
            aria-label={fast.label}
            disabled={fast.disabled}
            className={"row-control row-icon-only fast-toggle" + (fast.value ? " active" : "")}
            onClick={() => onChange(fast.id, !fast.value)}
          >
            <BoltIcon />
          </button>
        </HintTooltip>
      ) : null}
      {effortLike.map((option) => (
        <InlineSelect
          key={option.id}
          option={option}
          icon={<BarsIcon filled={effortFill(option)} />}
          choiceIcon={(value) => <BarsIcon filled={effortFill(option, value)} />}
          label={prettyValue(option)}
          onChange={onChange}
          open={openOptionId === option.id}
          onOpenChange={(open) => setOpenOptionId(open ? option.id : null)}
        />
      ))}
      {context ? (
        <InlineSelect
          option={context}
          icon={<SparkIcon />}
          label={prettyValue(context)}
          onChange={onChange}
          open={openOptionId === context.id}
          onOpenChange={(open) => setOpenOptionId(open ? context.id : null)}
        />
      ) : null}
      {mode && modeLabel ? (
        <HintTooltip label={optionTooltip(mode)} action="cycle-mode">
          <button type="button" className="row-control" onClick={() => cycleSelect(mode, onChange)}>
            <PlanIcon />
            <span className="row-value">{modeLabel}</span>
          </button>
        </HintTooltip>
      ) : null}
      {onCwdChange && onCwdCommit ? <CwdPopover cwd={cwd} onChange={onCwdChange} onCommit={onCwdCommit} /> : <StaticCwd cwd={cwd} />}
      {approval ? (
        <HintTooltip label={optionTooltip(approval)}>
          <button
            type="button"
            aria-label={approval.label}
            disabled={approval.disabled}
            className={"row-control row-icon-only shield-toggle" + (approval.value ? " active" : "")}
            onClick={() => onChange(approval.id, !approval.value)}
          >
            <ShieldIcon />
          </button>
        </HintTooltip>
      ) : null}
      <OverflowMenu options={overflow} onChange={onChange} />
      <div className="status-row-spacer" />
      {trailing}
    </div>
  );
}

function commandContext(text: string, caret: number, groups: CommandGroup[]) {
  const byTrigger = new Map(groups.map((g) => [g.trigger, g.commands]));
  const slash = byTrigger.get("/");
  if (slash && text.startsWith("/") && caret >= 1 && !/\s/.test(text.slice(1, caret))) {
    return { trigger: "/" as const, start: 0, query: text.slice(1, caret), commands: slash };
  }
  for (let i = caret - 1; i >= 0; i--) {
    if (/\s/.test(text[i])) break;
    const trigger = text[i] as CommandGroup["trigger"];
    const commands = byTrigger.get(trigger);
    if (commands && trigger !== "/" && (i === 0 || /\s/.test(text[i - 1]))) {
      const q = text.slice(i + 1, caret);
      if (!/\s/.test(q)) return { trigger, start: i, query: q, commands };
      return null;
    }
  }
  return null;
}

function fuzzyScore(name: string, query: string): number {
  const n = name.toLowerCase();
  const q = query.toLowerCase();
  if (!q) return 0;
  const direct = n.indexOf(q);
  if (direct >= 0) return direct;
  let pos = -1;
  let score = 0;
  for (const ch of q) {
    const next = n.indexOf(ch, pos + 1);
    if (next < 0) return Number.POSITIVE_INFINITY;
    score += next - pos;
    pos = next;
  }
  return score + n.length / 1000;
}

function isCtrlJ(e: React.KeyboardEvent<HTMLTextAreaElement>): boolean {
  return e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey && e.key.toLowerCase() === "j";
}

function insertNewlineAtCaret(text: string, setText: (v: string) => void, ref: RefObject<HTMLTextAreaElement | null>) {
  const el = ref.current;
  const start = el?.selectionStart ?? text.length;
  const end = el?.selectionEnd ?? start;
  const next = text.slice(0, start) + "\n" + text.slice(end);
  setText(next);
  requestAnimationFrame(() => {
    const pos = start + 1;
    ref.current?.focus();
    ref.current?.setSelectionRange(pos, pos);
  });
}

function useCommandMenu(
  text: string,
  setText: (v: string) => void,
  groups: CommandGroup[],
  ref: RefObject<HTMLTextAreaElement | null>,
  ctrlJ: CtrlJMode,
) {
  const [selected, setSelected] = useState(0);
  const [caret, setCaret] = useState(text.length);
  const syncCaret = useCallback(() => {
    setCaret(ref.current?.selectionStart ?? text.length);
  }, [ref, text.length]);
  useLayoutEffect(() => {
    setCaret(ref.current?.selectionStart ?? text.length);
  }, [ref, text]);
  const ctx = commandContext(text, caret, groups);
  const ctxKey = ctx ? `${ctx.trigger}:${ctx.start}:${ctx.query}` : "";
  const [dismissedKey, setDismissedKey] = useState("");
  const items = useMemo(() => {
    if (!ctx) return [];
    return ctx.commands
      .map((c) => ({ command: c, score: fuzzyScore(c.name, ctx.query) }))
      .filter((c) => Number.isFinite(c.score))
      .sort((a, b) => a.score - b.score || a.command.name.localeCompare(b.command.name))
      .map((c) => c.command)
      .slice(0, 12);
  }, [ctx?.trigger, ctx?.query, ctx?.commands]);
  const open = Boolean(ctx && items.length && dismissedKey !== ctxKey);
  useEffect(() => {
    setSelected(0);
  }, [ctxKey]);
  useEffect(() => {
    if (selected >= items.length) setSelected(0);
  }, [items.length, selected]);
  const close = useCallback(() => {
    setSelected(0);
    setDismissedKey(ctxKey);
  }, [ctxKey]);
  const insert = useCallback((cmd: CommandEntry) => {
    if (!ctx) return;
    const caret = ref.current?.selectionStart ?? text.length;
    const before = text.slice(0, ctx.start);
    const after = text.slice(caret);
    const next = `${before}${ctx.trigger}${cmd.name} ${after}`;
    setDismissedKey("");
    setText(next);
    requestAnimationFrame(() => {
      const pos = before.length + ctx.trigger.length + cmd.name.length + 1;
      ref.current?.focus();
      ref.current?.setSelectionRange(pos, pos);
    });
  }, [ctx, ref, setText, text]);
  const onKeyDown = useCallback((e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (!open) return false;
    const action = menuActionForKey(e.nativeEvent, ctrlJ);
    if (action === "menu-next") {
      e.preventDefault();
      e.stopPropagation();
      setSelected((i) => (i + 1) % items.length);
      return true;
    }
    if (action === "menu-prev") {
      e.preventDefault();
      e.stopPropagation();
      setSelected((i) => (i + items.length - 1) % items.length);
      return true;
    }
    if (action === "menu-accept") {
      e.preventDefault();
      e.stopPropagation();
      insert(items[selected] ?? items[0]);
      setSelected(0);
      return true;
    }
    if (action === "menu-close") {
      e.preventDefault();
      e.stopPropagation();
      close();
      return true;
    }
    return false;
  }, [close, ctrlJ, insert, items, open, selected]);
  const menu = open ? (
    <div className="command-menu">
      <CmdkMenu
        inline
        className="mention-menu"
        groups={[{
          id: ctx!.trigger,
          items: items.map((cmd, i) => ({
            id: cmd.name,
            label: `${ctx!.trigger}${cmd.name}`,
            description: cmd.description,
            onSelect: () => insert(cmd),
            value: `${cmd.name} ${cmd.description ?? ""}`,
          })),
        }]}
      />
    </div>
  ) : null;
  return { open, close, onKeyDown, onSelect: syncCaret, menu };
}

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

function actionSupported(action: KeyAction, options: SessionOption[], running: boolean): boolean {
  if (action === "help") return true;
  if (action === "interrupt") return running;
  if (action === "cycle-mode") return Boolean(options.find((o) => ["permissionMode", "mode", "approvals"].includes(o.id) && o.kind === "select" && !o.disabled));
  if (action === "cycle-model" || action === "open-model") return Boolean(options.find((o) => o.id === "model" && o.kind === "select" && !o.disabled));
  if (action === "cycle-thinking") return Boolean(options.find((o) => o.role === "effort" && o.kind === "select" && visibleChoices(o).length && !o.disabled));
  if (action === "toggle-fast") return Boolean(options.find((o) => o.id === "fastMode" && o.kind === "toggle" && !o.disabled));
  if (action === "toggle-plan") return Boolean(options.find((o) => (o.id === "mode" || o.id === "permissionMode") && o.choices?.some((c) => c.value === "plan") && !o.disabled));
  return false;
}

function useKeymap({
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
      const menuAction = menuActionForKey(e, ctrlJ);
      if (popupOpen && menuAction && menuAction !== "menu-close" && actionForKey(e)) return;
      const action = actionForKey(e);
      if (!action) return;
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

function ShortcutOverlay({ provider, options, running, ctrlJ, onClose }: { provider: string; options: SessionOption[]; running: boolean; ctrlJ: CtrlJMode; onClose: () => void }) {
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

function withLocalValues(options: SessionOption[], local: Record<string, OptionValue>): SessionOption[] {
  return options.map((o) => {
    if (!Object.prototype.hasOwnProperty.call(local, o.id)) return o;
    const value = local[o.id];
    return optionAcceptsValue(o, value) ? { ...o, value } : o;
  });
}

function optionAcceptsValue(option: SessionOption, value: OptionValue): boolean {
  if (option.kind === "toggle") return typeof value === "boolean";
  if (typeof value !== "string") return false;
  return Boolean(option.choices?.some((c) => c.value === value));
}

function sanitizeStartOptions(dirty: Record<string, OptionValue>, options: SessionOption[]): Record<string, OptionValue> {
  const byId = new Map(options.map((o) => [o.id, o]));
  const out: Record<string, OptionValue> = {};
  for (const [id, value] of Object.entries(dirty)) {
    const option = byId.get(id);
    if (option && optionAcceptsValue(option, value)) out[id] = value;
  }
  return out;
}

function readProviderOptions(provider: string): Record<string, OptionValue> {
  try {
    const raw = localStorage.getItem(`agentui.opts.${provider}`);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") return {};
    const out: Record<string, OptionValue> = {};
    for (const [id, value] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof value === "string" || typeof value === "boolean") out[id] = value;
    }
    return out;
  } catch {
    return {};
  }
}

function writeProviderOptions(provider: string, options: Record<string, OptionValue>) {
  localStorage.setItem(`agentui.opts.${provider}`, JSON.stringify(options));
}

function useDefaultCwd(
  defaultCwd: string,
  cwd: string,
  setCwd: (v: string) => void,
  committedCwd: string,
  setCommittedCwd: (v: string) => void,
) {
  useEffect(() => {
    if (!defaultCwd) return;
    if (!cwd) setCwd(defaultCwd);
    if (!committedCwd) setCommittedCwd(defaultCwd);
  }, [committedCwd, cwd, defaultCwd, setCommittedCwd, setCwd]);
}

function useProviderFallback(providers: Provider[], provider: string, setProvider: (v: string) => void) {
  useEffect(() => {
    const installed = providers.filter((p) => p.installed !== false);
    if (installed.length && !installed.some((p) => p.id === provider)) setProvider(installed[0].id);
  }, [providers, provider, setProvider]);
}

function useProviderCatalogs(
  ready: boolean,
  connectionEpoch: number,
  providers: Provider[],
  activeProvider: string,
  cwd: string,
  requestProviderOptions: (provider: string, cwd: string) => void,
  requestProviderCommands: (provider: string, cwd: string) => void,
) {
  useEffect(() => {
    if (!ready || !cwd) return;
    for (const provider of providers) {
      if (provider.installed === false) continue;
      requestProviderOptions(provider.id, cwd);
    }
    if (activeProvider && providers.some((p) => p.id === activeProvider && p.installed !== false)) {
      requestProviderCommands(activeProvider, cwd);
    }
  }, [activeProvider, connectionEpoch, cwd, providers, ready, requestProviderCommands, requestProviderOptions]);
}

function useFileCatalog(
  ready: boolean,
  connectionEpoch: number,
  cwd: string,
  requestFiles: (cwd: string, query?: string) => void,
) {
  useEffect(() => {
    if (!ready || !cwd) return;
    requestFiles(cwd);
  }, [connectionEpoch, cwd, ready, requestFiles]);
}

function withFileTrigger(groups: CommandGroup[], files: string[]): CommandGroup[] {
  return [
    ...groups,
    { trigger: "@", commands: files.map((name) => ({ name, description: "file" })) },
  ];
}

function providerOptionMap(providers: Provider[], providerOptions: Record<string, SessionOption[]>, capabilities: Record<string, { options: SessionOption[] }>): Record<string, SessionOption[]> {
  return Object.fromEntries(providers.map((p) => [
    p.id,
    providerOptions[p.id]?.length ? providerOptions[p.id] : capabilities[p.id]?.options ?? [],
  ]));
}

function useCwdValidation(
  ready: boolean,
  connectionEpoch: number,
  cwd: string,
  defaultCwd: string,
  cwdChecks: Record<string, { ok: boolean; message?: string }>,
  checkCwd: (cwd: string) => void,
  setCwd: (cwd: string) => void,
  setCommittedCwd: (cwd: string) => void,
) {
  useEffect(() => {
    if (ready && cwd) checkCwd(cwd);
  }, [checkCwd, connectionEpoch, cwd, ready]);
  useEffect(() => {
    const checked = cwdChecks[cwd];
    if (!checked || checked.ok || !defaultCwd) return;
    setCwd(defaultCwd);
    setCommittedCwd(defaultCwd);
    localStorage.setItem("agentui.cwd", defaultCwd);
  }, [cwd, cwdChecks, defaultCwd, setCommittedCwd, setCwd]);
}

function useCwdErrorFallback(
  message: string,
  defaultCwd: string,
  setCwd: (cwd: string) => void,
  setCommittedCwd: (cwd: string) => void,
) {
  useEffect(() => {
    if (!message.includes("working directory does not exist") || !defaultCwd) return;
    setCwd(defaultCwd);
    setCommittedCwd(defaultCwd);
    localStorage.setItem("agentui.cwd", defaultCwd);
  }, [defaultCwd, message, setCommittedCwd, setCwd]);
}

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  const tag = target.tagName.toLowerCase();
  return tag === "textarea" || tag === "input" || tag === "select" || target.isContentEditable;
}

function primaryTextarea(): HTMLTextAreaElement | null {
  return document.querySelector<HTMLTextAreaElement>("[data-primary-textarea='true']");
}

function useTypeToFocus() {
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.isComposing || isEditableTarget(e.target) || e.defaultPrevented) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key.length !== 1) return;
      primaryTextarea()?.focus();
    };
    const onPaste = (e: ClipboardEvent) => {
      if (isEditableTarget(e.target) || e.defaultPrevented) return;
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

function Composer() {
  const {
    ready,
    connectionEpoch,
    providers,
    capabilities,
    defaultCwd,
    providerOptions,
    providerCommands,
    filesByCwd,
    cwdChecks,
    lastError,
    ctrlJ,
    requestProviderOptions,
    requestProviderCommands,
    requestFiles,
    checkCwd,
    clearError,
    start,
  } = useCtx();
  const [provider, setProvider] = useState(() => localStorage.getItem("agentui.provider") || "claude");
  const [cwd, setCwd] = useState(() => localStorage.getItem("agentui.cwd") || "");
  const [committedCwd, setCommittedCwd] = useState(() => localStorage.getItem("agentui.cwd") || "");
  const [prompt, setPrompt] = useState(() => {
    const draft = sessionStorage.getItem("agentui.draft") || "";
    sessionStorage.removeItem("agentui.draft");
    return draft;
  });
  const [startOptionsByProvider, setStartOptionsByProvider] = useState<Record<string, Record<string, OptionValue>>>(() => ({
    [provider]: readProviderOptions(provider),
  }));
  const [openOptionId, setOpenOptionId] = useState<string | null>(null);
  const [helpOpen, setHelpOpen] = useState(false);
  const taRef = useAutoGrow(prompt, 300);
  const baseOptions = providerOptions[provider]?.length ? providerOptions[provider] : capabilities[provider]?.options ?? [];
  const allProviderOptions = providerOptionMap(providers, providerOptions, capabilities);
  const startOptions = startOptionsByProvider[provider] ?? {};
  const options = withLocalValues(baseOptions, startOptions);
  const commandGroups = useMemo(() => withFileTrigger(providerCommands[provider] ?? [], filesByCwd[committedCwd] ?? []), [committedCwd, filesByCwd, provider, providerCommands]);
  const commandMenu = useCommandMenu(prompt, setPrompt, commandGroups, taRef, ctrlJ);

  useDefaultCwd(defaultCwd, cwd, setCwd, committedCwd, setCommittedCwd);
  useProviderFallback(providers, provider, setProvider);
  useProviderCatalogs(ready, connectionEpoch, providers, provider, committedCwd, requestProviderOptions, requestProviderCommands);
  useFileCatalog(ready, connectionEpoch, committedCwd, requestFiles);
  useCwdValidation(ready, connectionEpoch, committedCwd, defaultCwd, cwdChecks, checkCwd, setCwd, setCommittedCwd);
  useCwdErrorFallback(lastError, defaultCwd, setCwd, setCommittedCwd);

  const setLocalOption = useCallback((id: string, value: OptionValue) => {
    setStartOptionsByProvider((all) => {
      const nextForProvider = { ...(all[provider] ?? readProviderOptions(provider)), [id]: value };
      writeProviderOptions(provider, nextForProvider);
      return { ...all, [provider]: nextForProvider };
    });
  }, [provider]);
  useKeymap({
    options,
    setOption: setLocalOption,
    running: false,
    stop: () => {},
    helpOpen,
    setHelpOpen,
    popupOpen: commandMenu.open || Boolean(openOptionId),
    closePopup: () => {
      commandMenu.close();
      setOpenOptionId(null);
    },
    ctrlJ,
    inputRef: taRef,
    openModel: () => setOpenOptionId("modelPicker"),
  });

  const submit = () => {
    const text = prompt.trim();
    if (!text) return;
    const runCwd = cwd.trim();
    localStorage.setItem("agentui.provider", provider);
    localStorage.setItem("agentui.cwd", runCwd);
    start({ provider, cwd: runCwd, prompt: text, options: sanitizeStartOptions(startOptions, options) });
    setPrompt("");
  };
  const changeCwd = (v: string) => { setCwd(v); };
  const commitCwd = (v: string) => {
    const next = v.trim();
    if (!next) return;
    setCommittedCwd(next);
    localStorage.setItem("agentui.cwd", next);
  };
  const changeProvider = (v: string) => {
    setProvider(v);
    setStartOptionsByProvider((all) => all[v] ? all : { ...all, [v]: readProviderOptions(v) });
    localStorage.setItem("agentui.provider", v);
  };
  const changeProviderModel = (nextProvider: string, model: string) => {
    changeProvider(nextProvider);
    setStartOptionsByProvider((all) => {
      const nextForProvider = { ...(all[nextProvider] ?? readProviderOptions(nextProvider)) };
      if (model) nextForProvider.model = model;
      else delete nextForProvider.model;
      writeProviderOptions(nextProvider, nextForProvider);
      return { ...all, [nextProvider]: nextForProvider };
    });
    setOpenOptionId(null);
  };

  return (
    <section id="composer-view">
      <div id="composer-card">
        <div className="input-wrap">
          <textarea
            ref={taRef}
            id="prompt-input"
            data-primary-textarea="true"
            placeholder="Describe a task or ask a question…"
            value={prompt}
            autoFocus
            onChange={(e) => setPrompt(e.target.value)}
            onSelect={commandMenu.onSelect}
            onKeyUp={commandMenu.onSelect}
            onClick={commandMenu.onSelect}
            onKeyDown={(e) => {
              if (commandMenu.onKeyDown(e)) return;
              if (isCtrlJ(e)) { e.preventDefault(); insertNewlineAtCaret(prompt, setPrompt, taRef); return; }
              if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); }
            }}
            onFocus={clearError}
          />
          {commandMenu.menu}
        </div>
        <StatusRow
          provider={provider}
          providers={providers}
          allProviderOptions={allProviderOptions}
          onProviderModelChange={changeProviderModel}
          cwd={cwd}
          onCwdChange={changeCwd}
          onCwdCommit={commitCwd}
          options={options}
          onChange={setLocalOption}
          openOptionId={openOptionId}
          setOpenOptionId={setOpenOptionId}
          trailing={(
            <button className="send" type="button" aria-label="Start" disabled={!prompt.trim()} onClick={submit}>
              <ArrowUp />
            </button>
          )}
        />
      </div>
      {lastError ? <div className="composer-error">{lastError}</div> : null}
      <div id="composer-hint">Enter to start · Shift+Enter for newline · Ctrl+/ for shortcuts</div>
      {helpOpen ? <ShortcutOverlay provider={provider} options={options} running={false} ctrlJ={ctrlJ} onClose={() => setHelpOpen(false)} /> : null}
    </section>
  );
}

function ToolBlock({ b }: { b: Extract<Block, { kind: "tool" }> }) {
  return (
    <div className="tool">
      <details>
        <summary>
          {b.status === "running"
            ? <span className="spinner" />
            : <span className={"mark " + (b.status === "fail" ? "fail" : "ok")}>{b.status === "fail" ? "✗" : "✓"}</span>}
          <span className="name">{b.name}</span>
          <span className="detail">{b.detail}</span>
        </summary>
        {b.out ? <div className="out">{b.out}</div> : null}
      </details>
    </div>
  );
}

function durationText(stats: string): string {
  return stats.split(" · ").find((part) => /^\d+(\.\d+)?s$/.test(part.trim())) ?? "";
}

function TurnActions({ stats, text, actions, onFork }: { stats: string; text: string; actions: SessionActions; onFork: () => void }) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    navigator.clipboard?.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 900);
    }).catch(() => {});
  };
  return (
    <div className="turn-actions">
      <span className="turn-duration">{durationText(stats)}</span>
      <button className="turn-action-btn" type="button" aria-label="Copy response" onClick={copy}>
        {copied ? <Check /> : <CopyIcon />}
      </button>
      <Popover.Root>
        <Popover.Trigger className="turn-action-btn" aria-label="Message actions"><EllipsisIcon /></Popover.Trigger>
        <Popover.Portal>
          <Popover.Positioner sideOffset={6} align="start">
            <Popover.Popup className="turn-menu menu">
              {stats ? <div className="turn-menu-stats">{stats}</div> : null}
              {actions.fork ? <button className="turn-menu-item" type="button" onClick={onFork}>Fork chat</button> : null}
            </Popover.Popup>
          </Popover.Positioner>
        </Popover.Portal>
      </Popover.Root>
    </div>
  );
}

function Blocks({ blocks, actions, onFork }: { blocks: Block[]; actions: SessionActions; onFork: () => void }) {
  let lastAssistant = "";
  return (
    <>
      {blocks.map((b, i) => {
        switch (b.kind) {
          case "user":
            return <div className="msg user" key={i}><div className="body">{b.text}</div></div>;
          case "assistant":
            lastAssistant = b.text;
            return <div className="msg assistant" key={i}><div className="body" dangerouslySetInnerHTML={{ __html: renderMd(b.text) }} /></div>;
          case "thinking":
            return (
              <details className="thinking" key={i}>
                <summary>thinking</summary>
                <div className="t-body">{b.text}</div>
              </details>
            );
          case "tool":
            return <ToolBlock b={b} key={i} />;
          case "status":
            return <div className="status-line" key={i}>{b.text}</div>;
          case "error":
            return <div className="error-block-wrap" key={i}><div className="error-block">{b.text}</div></div>;
          case "footer":
            return <TurnActions key={i} stats={b.text} text={lastAssistant} actions={actions} onFork={onFork} />;
        }
      })}
    </>
  );
}

function Chat() {
  const { ready, connectionEpoch, providers, capabilities, providerOptions, providerCommands, session, blocks, options, actions, commands, filesByCwd, ctrlJ, reply, stop, setOption, fork, compose, requestProviderOptions, requestProviderCommands, requestFiles } = useCtx();
  const [text, setText] = useState("");
  const [openOptionId, setOpenOptionId] = useState<string | null>(null);
  const [helpOpen, setHelpOpen] = useState(false);
  const taRef = useAutoGrow(text, 200);
  const scrollRef = useRef<HTMLDivElement>(null);
  const stickRef = useRef(true);
  const cwd = session?.cwd ?? "";
  const commandGroups = useMemo(() => withFileTrigger(commands, filesByCwd[cwd] ?? []), [commands, cwd, filesByCwd]);
  const commandMenu = useCommandMenu(text, setText, commandGroups, taRef, ctrlJ);
  const allProviderOptions = providerOptionMap(providers, providerOptions, capabilities);
  const running = session?.status === "running";

  useProviderCatalogs(ready, connectionEpoch, providers, session?.provider ?? "", cwd, requestProviderOptions, requestProviderCommands);
  useFileCatalog(ready, connectionEpoch, cwd, requestFiles);
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (el && stickRef.current) el.scrollTop = el.scrollHeight;
  }, [blocks]);
  useKeymap({
    options,
    setOption,
    running,
    stop,
    helpOpen,
    setHelpOpen,
    popupOpen: commandMenu.open || Boolean(openOptionId),
    closePopup: () => {
      commandMenu.close();
      setOpenOptionId(null);
    },
    ctrlJ,
    inputRef: taRef,
    openModel: () => setOpenOptionId("modelPicker"),
  });

  const onScroll = () => {
    const el = scrollRef.current;
    if (el) stickRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
  };
  const submit = () => {
    const t = text.trim();
    if (!t) return;
    stickRef.current = true;
    reply(t);
    setText("");
  };
  const switchHarnessModel = (provider: string, model: string) => {
    if (!session) return;
    if (provider === session.provider) {
      if (model) setOption("model", model);
      setOpenOptionId(null);
      return;
    }
    const nextOptions = { ...readProviderOptions(provider) };
    if (model) nextOptions.model = model;
    else delete nextOptions.model;
    writeProviderOptions(provider, nextOptions);
    localStorage.setItem("agentui.provider", provider);
    localStorage.setItem("agentui.cwd", session.cwd);
    sessionStorage.setItem("agentui.draft", text);
    compose();
  };

  return (
    <section id="chat-view">
      <div id="messages" ref={scrollRef} onScroll={onScroll}>
        <Blocks blocks={blocks} actions={actions} onFork={fork} />
      </div>
      <div id="chat-input-row">
        <div id="chat-card">
          <div className="input-wrap chat-text-wrap">
            <textarea
              ref={taRef}
              id="chat-input"
              data-primary-textarea="true"
              placeholder="Reply…"
              value={text}
              onChange={(e) => setText(e.target.value)}
              onSelect={commandMenu.onSelect}
              onKeyUp={commandMenu.onSelect}
              onClick={commandMenu.onSelect}
              onKeyDown={(e) => {
                if (commandMenu.onKeyDown(e)) return;
                if (isCtrlJ(e)) { e.preventDefault(); insertNewlineAtCaret(text, setText, taRef); return; }
                if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); }
              }}
            />
            {commandMenu.menu}
          </div>
          <StatusRow
            provider={session?.provider ?? "agent"}
            providers={providers}
            allProviderOptions={allProviderOptions}
            onProviderModelChange={switchHarnessModel}
            cwd={session?.cwd ?? ""}
            options={options}
            onChange={setOption}
            openOptionId={openOptionId}
            setOpenOptionId={setOpenOptionId}
            trailing={(
              <div className="chat-actions">
              {running ? <button id="stop-btn" type="button" onClick={stop}>Stop</button> : null}
              <button className="send" type="button" aria-label="Send" disabled={!text.trim()} onClick={submit}>
                <ArrowUp />
              </button>
              </div>
            )}
          />
        </div>
      </div>
      {helpOpen ? <ShortcutOverlay provider={session?.provider ?? "agent"} options={options} running={running} ctrlJ={ctrlJ} onClose={() => setHelpOpen(false)} /> : null}
    </section>
  );
}

export function App() {
  const s = useSession();
  useTypeToFocus();
  return (
    <Ctx.Provider value={s}>
      <main id="main">
        {!s.ready && s.phase === "composer" ? null : s.phase === "chat" ? <Chat /> : <Composer />}
      </main>
    </Ctx.Provider>
  );
}
