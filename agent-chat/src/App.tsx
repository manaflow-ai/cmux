import { createContext, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactElement, type ReactNode, type RefObject } from "react";
import { Select } from "@base-ui-components/react/select";
import { Popover } from "@base-ui-components/react/popover";
import { Tooltip } from "@base-ui-components/react/tooltip";
import {
  useSession,
  type Block,
  type CommandEntry,
  type CommandGroup,
  type OptionValue,
  type Provider,
  type SessionOption,
  type SessionState,
} from "./session";
import { renderMd } from "./md";
import { KEYMAP, actionForKey, type KeyAction } from "./keymap";

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

function ProviderIcon({ id }: { id: string }) {
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
const BarsIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M3 12V9.8M6.3 12V7.8M9.6 12V5.6M12.9 12V3.8" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" /></svg>
);
const PlanIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M2.5 4.3l3.4-1.5 4.2 1.5 3.4-1.5v8.9l-3.4 1.5-4.2-1.5-3.4 1.5V4.3zM5.9 2.8v8.9M10.1 4.3v8.9" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
const ShieldIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M8 2.2l4.7 1.7v3.6c0 3.1-1.9 5.3-4.7 6.3-2.8-1-4.7-3.2-4.7-6.3V3.9L8 2.2z" fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinejoin="round" /><path d="M5.8 7.9l1.4 1.4 3-3.1" fill="none" stroke="currentColor" strokeWidth="1.35" strokeLinecap="round" strokeLinejoin="round" /></svg>
);
const EllipsisIcon = () => (
  <svg viewBox="0 0 16 16" width="15" height="15"><path d="M3.5 8h.1M8 8h.1M12.5 8h.1" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" /></svg>
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

function ProviderSelect({ providers, value, onChange }: { providers: Provider[]; value: string; onChange: (v: string) => void }) {
  const label = providers.find((p) => p.id === value)?.label ?? value;
  return (
    <Select.Root value={value} onValueChange={(v) => onChange(v as string)}>
      <HintTooltip label="Switch provider">
        <Select.Trigger className="row-control provider-trigger select-trigger">
          <ProviderIcon id={value} />
          <span className="row-value">{label}</span>
          <Select.Icon className="chev"><Chevron /></Select.Icon>
        </Select.Trigger>
      </HintTooltip>
      <Select.Portal>
        <Select.Positioner className="select-positioner" sideOffset={8} align="start">
          <Select.Popup className="menu">
            {providers.map((p) => (
              <Select.Item key={p.id} value={p.id} className="menu-item">
                <ProviderIcon id={p.id} />
                <Select.ItemText>{p.label}</Select.ItemText>
                <Select.ItemIndicator className="mi-check"><Check /></Select.ItemIndicator>
              </Select.Item>
            ))}
          </Select.Popup>
        </Select.Positioner>
      </Select.Portal>
    </Select.Root>
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
  if (option.id === "effort") return "Adjust effort level";
  if (option.id === "thinking") return "Adjust thinking level";
  if (option.id === "fastMode") return "Toggle fast mode";
  if (option.id === "mode" || option.id === "permissionMode") return "Change mode";
  return `Adjust ${option.label}`;
}

function InlineSelect({
  option,
  icon,
  label,
  onChange,
  open,
  onOpenChange,
}: {
  option: SessionOption;
  icon: ReactNode;
  label: string;
  onChange: (id: string, value: OptionValue) => void;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const value = String(option.value ?? "");
  const choices = option.choices?.length
    ? option.choices
    : (value ? [{ value, label: value }] : []);
  const current = choices.find((c) => c.value === value)?.label ?? (value || option.label);
  return (
    <Select.Root
      value={value}
      disabled={option.disabled || !choices.length}
      open={open}
      onOpenChange={(next) => onOpenChange(next)}
      onValueChange={(v) => onChange(option.id, String(v))}
    >
      <HintTooltip label={optionTooltip(option)} action={optionAction(option.id)}>
        <Select.Trigger className="row-control row-select select-trigger" aria-label={option.label}>
          <span className="row-icon">{icon}</span>
          <span className="row-value">{label || current}</span>
        </Select.Trigger>
      </HintTooltip>
      <Select.Portal>
        <Select.Positioner className="select-positioner" sideOffset={8} align="start">
          <Select.Popup className="menu option-menu">
            {choices.map((c) => (
              <Select.Item key={c.value} value={c.value} className="menu-item" title={c.description}>
                <Select.ItemText>{c.label}</Select.ItemText>
                <Select.ItemIndicator className="mi-check"><Check /></Select.ItemIndicator>
              </Select.Item>
            ))}
          </Select.Popup>
        </Select.Positioner>
      </Select.Portal>
    </Select.Root>
  );
}

function cycleSelect(option: SessionOption, onChange: (id: string, value: OptionValue) => void) {
  if (option.kind !== "select" || !option.choices?.length || option.disabled) return;
  const i = option.choices.findIndex((c) => c.value === option.value);
  const next = option.choices[(i + 1 + option.choices.length) % option.choices.length];
  if (next) onChange(option.id, next.value);
}

const INLINE_OPTION_IDS = new Set(["model", "effort", "thinking", "fastMode", "mode", "permissionMode"]);

function OverflowMenu({ options, onChange }: { options: SessionOption[]; onChange: (id: string, value: OptionValue) => void }) {
  if (!options.length) return null;
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
            {options.map((option) => (
              <div className="overflow-option" key={option.id}>
                <div className="overflow-title">{option.label}</div>
                {option.kind === "toggle" ? (
                  <button
                    type="button"
                    className={"overflow-toggle" + (option.value ? " active" : "")}
                    disabled={option.disabled}
                    onClick={() => onChange(option.id, !option.value)}
                  >
                    {option.value ? "On" : "Off"}
                  </button>
                ) : (
                  <div className="overflow-choices">
                    {(option.choices ?? []).map((choice) => (
                      <button
                        type="button"
                        key={choice.value}
                        className={"overflow-choice" + (choice.value === option.value ? " active" : "")}
                        disabled={option.disabled}
                        onClick={() => onChange(option.id, choice.value)}
                      >
                        {choice.label}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            ))}
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function StaticProvider({ provider }: { provider: string }) {
  return (
    <HintTooltip label="Provider">
      <span className="row-control static-provider">
        <ProviderIcon id={provider} />
        <span className="row-value">{provider}</span>
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

function StatusRow({
  provider,
  providers,
  onProviderChange,
  cwd,
  onCwdChange,
  onCwdCommit,
  options,
  onChange,
  openOptionId,
  setOpenOptionId,
  autoApprove,
  setAutoApprove,
  trailing,
}: {
  provider: string;
  providers?: Provider[];
  onProviderChange?: (v: string) => void;
  cwd: string;
  onCwdChange?: (v: string) => void;
  onCwdCommit?: (v: string) => void;
  options: SessionOption[];
  onChange: (id: string, value: OptionValue) => void;
  openOptionId: string | null;
  setOpenOptionId: (id: string | null) => void;
  autoApprove?: boolean;
  setAutoApprove?: (v: boolean) => void;
  trailing?: ReactNode;
}) {
  const model = options.find((o) => o.id === "model" && o.kind === "select");
  const effortLike = options.filter((o) => (o.id === "effort" || o.id === "thinking") && o.kind === "select");
  const fast = options.find((o) => o.id === "fastMode" && o.kind === "toggle");
  const mode = options.find((o) => (o.id === "mode" || o.id === "permissionMode") && o.kind === "select");
  const overflow = options.filter((o) => !INLINE_OPTION_IDS.has(o.id));
  const modeLabel = mode && !["", "default", "build"].includes(String(mode.value)) ? prettyValue(mode) : "";
  return (
    <div className="status-row">
      {providers && onProviderChange
        ? <ProviderSelect providers={providers} value={provider} onChange={onProviderChange} />
        : <StaticProvider provider={provider} />}
      {model ? (
        <InlineSelect
          option={model}
          icon={<SparkIcon />}
          label={currentChoice(model)?.label ?? String(model.value || "Model")}
          onChange={onChange}
          open={openOptionId === model.id}
          onOpenChange={(open) => setOpenOptionId(open ? model.id : null)}
        />
      ) : null}
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
          icon={<BarsIcon />}
          label={prettyValue(option)}
          onChange={onChange}
          open={openOptionId === option.id}
          onOpenChange={(open) => setOpenOptionId(open ? option.id : null)}
        />
      ))}
      {mode && modeLabel ? (
        <HintTooltip label={optionTooltip(mode)} action="cycle-mode">
          <button type="button" className="row-control" onClick={() => cycleSelect(mode, onChange)}>
            <PlanIcon />
            <span className="row-value">{modeLabel}</span>
          </button>
        </HintTooltip>
      ) : null}
      {onCwdChange && onCwdCommit ? <CwdPopover cwd={cwd} onChange={onCwdChange} onCommit={onCwdCommit} /> : <StaticCwd cwd={cwd} />}
      {setAutoApprove ? (
        <HintTooltip label="Toggle auto-approve">
          <button
            type="button"
            aria-label="Auto-approve"
            className={"row-control row-icon-only shield-toggle" + (autoApprove ? " active" : "")}
            onClick={() => setAutoApprove(!autoApprove)}
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
  const slash = groups.find((g) => g.trigger === "/");
  if (slash && text.startsWith("/") && caret >= 1 && !/\s/.test(text.slice(1, caret))) {
    return { trigger: "/" as const, start: 0, query: text.slice(1, caret), commands: slash.commands };
  }
  const dollar = groups.find((g) => g.trigger === "$");
  if (!dollar) return null;
  for (let i = caret - 1; i >= 0; i--) {
    if (text[i] === "$" && (i === 0 || /\s/.test(text[i - 1]))) {
      const q = text.slice(i + 1, caret);
      if (!/\s/.test(q)) return { trigger: "$" as const, start: i, query: q, commands: dollar.commands };
      return null;
    }
    if (/\s/.test(text[i])) break;
  }
  return null;
}

function useCommandMenu(
  text: string,
  setText: (v: string) => void,
  groups: CommandGroup[],
  ref: RefObject<HTMLTextAreaElement | null>,
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
    const q = ctx.query.toLowerCase();
    return ctx.commands
      .filter((c) => c.name.toLowerCase().includes(q))
      .slice(0, 12);
  }, [ctx?.trigger, ctx?.query, ctx?.commands]);
  const open = Boolean(ctx && items.length && dismissedKey !== ctxKey);
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
    if (e.key === "ArrowDown") {
      e.preventDefault();
      e.stopPropagation();
      setSelected((i) => (i + 1) % items.length);
      return true;
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      e.stopPropagation();
      setSelected((i) => (i + items.length - 1) % items.length);
      return true;
    }
    if (e.key === "Enter" || e.key === "Tab") {
      e.preventDefault();
      e.stopPropagation();
      insert(items[selected] ?? items[0]);
      setSelected(0);
      return true;
    }
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      close();
      return true;
    }
    return false;
  }, [insert, items, open, selected]);
  const menu = open ? (
    <div className="command-menu menu">
      {items.map((cmd, i) => (
        <button
          key={cmd.name}
          type="button"
          className={"command-item menu-item" + (i === selected ? " active" : "")}
          onMouseDown={(e) => { e.preventDefault(); insert(cmd); }}
        >
          <span className="cmd-name">{ctx!.trigger}{cmd.name}</span>
          {cmd.description ? <span className="cmd-desc">{cmd.description}</span> : null}
        </button>
      ))}
    </div>
  ) : null;
  return { open, close, onKeyDown, onSelect: syncCaret, menu };
}

function cycleOption(options: SessionOption[], ids: string[], setOption: (id: string, value: OptionValue) => void) {
  const opt = ids.map((id) => options.find((o) => o.id === id)).find(Boolean);
  if (!opt || opt.kind !== "select" || !opt.choices?.length || opt.disabled) return false;
  const i = opt.choices.findIndex((c) => c.value === opt.value);
  const next = opt.choices[(i + 1 + opt.choices.length) % opt.choices.length];
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
  if (action === "cycle-thinking") return Boolean(options.find((o) => (o.id === "thinking" || o.id === "effort") && o.kind === "select" && !o.disabled));
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
  commandOpen,
  closeCommand,
  inputRef,
  openModel,
}: {
  options: SessionOption[];
  setOption: (id: string, value: OptionValue) => void;
  running: boolean;
  stop: () => void;
  helpOpen: boolean;
  setHelpOpen: (v: boolean) => void;
  commandOpen: boolean;
  closeCommand: () => void;
  inputRef: RefObject<HTMLTextAreaElement | null>;
  openModel: () => void;
}) {
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      const action = actionForKey(e);
      if (!action) return;
      if (commandOpen && e.key === "Tab") return;
      if (action === "help" && e.key === "?" && inputRef.current && inputRef.current.value.trim()) return;
      if (action === "interrupt") {
        if (helpOpen) {
          e.preventDefault();
          setHelpOpen(false);
          return;
        }
        if (commandOpen) {
          e.preventDefault();
          closeCommand();
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
      else if (action === "cycle-thinking") cycleOption(options, ["thinking", "effort"], setOption);
      else if (action === "toggle-fast") {
        const opt = options.find((o) => o.id === "fastMode" && o.kind === "toggle" && !o.disabled);
        if (opt) setOption(opt.id, !opt.value);
      } else if (action === "toggle-plan") {
        togglePlan(options, setOption);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [closeCommand, commandOpen, helpOpen, inputRef, openModel, options, running, setHelpOpen, setOption, stop]);
}

function ShortcutOverlay({ provider, options, running, onClose }: { provider: string; options: SessionOption[]; running: boolean; onClose: () => void }) {
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
      </div>
    </div>
  );
}

function withLocalValues(options: SessionOption[], local: Record<string, OptionValue>): SessionOption[] {
  return options.map((o) => Object.prototype.hasOwnProperty.call(local, o.id) ? { ...o, value: local[o.id] } : o);
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
    if (providers.length && !providers.some((p) => p.id === provider)) setProvider(providers[0].id);
  }, [providers, provider, setProvider]);
}

function useProviderCatalog(
  ready: boolean,
  connectionEpoch: number,
  provider: string,
  cwd: string,
  requestProviderOptions: (provider: string, cwd: string) => void,
  requestProviderCommands: (provider: string, cwd: string) => void,
) {
  useEffect(() => {
    if (!ready || !provider || !cwd) return;
    requestProviderOptions(provider, cwd);
    requestProviderCommands(provider, cwd);
  }, [connectionEpoch, cwd, provider, ready, requestProviderCommands, requestProviderOptions]);
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
    requestProviderOptions,
    requestProviderCommands,
    start,
  } = useCtx();
  const [provider, setProvider] = useState(() => localStorage.getItem("agentui.provider") || "claude");
  const [cwd, setCwd] = useState(() => localStorage.getItem("agentui.cwd") || "");
  const [committedCwd, setCommittedCwd] = useState(() => localStorage.getItem("agentui.cwd") || "");
  const [prompt, setPrompt] = useState("");
  const [autoApprove, setAutoApprove] = useState(true);
  const [startOptions, setStartOptions] = useState<Record<string, OptionValue>>({});
  const [openOptionId, setOpenOptionId] = useState<string | null>(null);
  const [helpOpen, setHelpOpen] = useState(false);
  const taRef = useAutoGrow(prompt, 300);
  const baseOptions = providerOptions[provider]?.length ? providerOptions[provider] : capabilities[provider]?.options ?? [];
  const options = withLocalValues(baseOptions, startOptions);
  const commandGroups = providerCommands[provider] ?? [];
  const commandMenu = useCommandMenu(prompt, setPrompt, commandGroups, taRef);

  useDefaultCwd(defaultCwd, cwd, setCwd, committedCwd, setCommittedCwd);
  useProviderFallback(providers, provider, setProvider);
  useProviderCatalog(ready, connectionEpoch, provider, committedCwd, requestProviderOptions, requestProviderCommands);

  const setLocalOption = useCallback((id: string, value: OptionValue) => {
    setStartOptions((m) => ({ ...m, [id]: value }));
  }, []);
  useKeymap({
    options,
    setOption: setLocalOption,
    running: false,
    stop: () => {},
    helpOpen,
    setHelpOpen,
    commandOpen: commandMenu.open,
    closeCommand: commandMenu.close,
    inputRef: taRef,
    openModel: () => setOpenOptionId("model"),
  });

  const submit = () => {
    const text = prompt.trim();
    if (!text) return;
    const runCwd = cwd.trim();
    localStorage.setItem("agentui.provider", provider);
    localStorage.setItem("agentui.cwd", runCwd);
    start({ provider, cwd: runCwd, prompt: text, autoApprove, options: startOptions });
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
    setStartOptions({});
    localStorage.setItem("agentui.provider", v);
  };

  return (
    <section id="composer-view">
      <h1>What should the agent do?</h1>
      <div id="composer-card">
        <div className="input-wrap">
          <textarea
            ref={taRef}
            id="prompt-input"
            placeholder="Describe a task or ask a question…"
            value={prompt}
            autoFocus
            onChange={(e) => setPrompt(e.target.value)}
            onSelect={commandMenu.onSelect}
            onKeyUp={commandMenu.onSelect}
            onClick={commandMenu.onSelect}
            onKeyDown={(e) => {
              if (commandMenu.onKeyDown(e)) return;
              if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); }
            }}
          />
          {commandMenu.menu}
        </div>
        <StatusRow
          provider={provider}
          providers={providers}
          onProviderChange={changeProvider}
          cwd={cwd}
          onCwdChange={changeCwd}
          onCwdCommit={commitCwd}
          options={options}
          onChange={setLocalOption}
          openOptionId={openOptionId}
          setOpenOptionId={setOpenOptionId}
          autoApprove={autoApprove}
          setAutoApprove={setAutoApprove}
          trailing={(
            <button className="send" type="button" aria-label="Start" disabled={!prompt.trim()} onClick={submit}>
              <ArrowUp />
            </button>
          )}
        />
      </div>
      <div id="composer-hint">Enter to start · Shift+Enter for newline · Ctrl+/ for shortcuts</div>
      {helpOpen ? <ShortcutOverlay provider={provider} options={options} running={false} onClose={() => setHelpOpen(false)} /> : null}
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

function Blocks({ blocks }: { blocks: Block[] }) {
  return (
    <>
      {blocks.map((b, i) => {
        switch (b.kind) {
          case "user":
            return <div className="msg user" key={i}><div className="body">{b.text}</div></div>;
          case "assistant":
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
            return <div className="turn-footer" key={i}>{b.text}</div>;
        }
      })}
    </>
  );
}

function Chat() {
  const { session, blocks, options, commands, reply, stop, setOption } = useCtx();
  const [text, setText] = useState("");
  const [openOptionId, setOpenOptionId] = useState<string | null>(null);
  const [helpOpen, setHelpOpen] = useState(false);
  const taRef = useAutoGrow(text, 200);
  const scrollRef = useRef<HTMLDivElement>(null);
  const stickRef = useRef(true);
  const commandMenu = useCommandMenu(text, setText, commands, taRef);
  const running = session?.status === "running";

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
    commandOpen: commandMenu.open,
    closeCommand: commandMenu.close,
    inputRef: taRef,
    openModel: () => setOpenOptionId("model"),
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

  return (
    <section id="chat-view">
      <div id="messages" ref={scrollRef} onScroll={onScroll}>
        <Blocks blocks={blocks} />
      </div>
      <div id="chat-input-row">
        <div id="chat-card">
          <div className="input-wrap chat-text-wrap">
            <textarea
              ref={taRef}
              id="chat-input"
              placeholder="Reply…"
              value={text}
              onChange={(e) => setText(e.target.value)}
              onSelect={commandMenu.onSelect}
              onKeyUp={commandMenu.onSelect}
              onClick={commandMenu.onSelect}
              onKeyDown={(e) => {
                if (commandMenu.onKeyDown(e)) return;
                if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); }
              }}
            />
            {commandMenu.menu}
          </div>
          <StatusRow
            provider={session?.provider ?? "agent"}
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
      {helpOpen ? <ShortcutOverlay provider={session?.provider ?? "agent"} options={options} running={running} onClose={() => setHelpOpen(false)} /> : null}
    </section>
  );
}

export function App() {
  const s = useSession();
  return (
    <Ctx.Provider value={s}>
      <main id="main">
        {!s.ready && s.phase === "composer" ? null : s.phase === "chat" ? <Chat /> : <Composer />}
      </main>
    </Ctx.Provider>
  );
}
