import { createContext, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type RefObject } from "react";
import { Select } from "@base-ui-components/react/select";
import { Switch } from "@base-ui-components/react/switch";
import { Popover } from "@base-ui-components/react/popover";
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

function ProviderSelect({ providers, value, onChange }: { providers: Provider[]; value: string; onChange: (v: string) => void }) {
  const label = providers.find((p) => p.id === value)?.label ?? value;
  return (
    <Select.Root value={value} onValueChange={(v) => onChange(v as string)}>
      <Select.Trigger className="chip select-trigger">
        <Dot id={value} />
        <span className="select-value">{label}</span>
        <Select.Icon className="chev"><Chevron /></Select.Icon>
      </Select.Trigger>
      <Select.Portal>
        <Select.Positioner className="select-positioner" sideOffset={8} align="start">
          <Select.Popup className="menu">
            {providers.map((p) => (
              <Select.Item key={p.id} value={p.id} className="menu-item">
                <Dot id={p.id} />
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
      <Popover.Trigger className="chip" title={cwd}>
        <FolderIcon />
        <span className="cwd-label">{basename(cwd)}</span>
      </Popover.Trigger>
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

function optionHint(id: string): string {
  if (id === "model") return "Ctrl+P cycles · Ctrl+Shift+P opens";
  if (id === "effort" || id === "thinking") return "Ctrl+T";
  if (id === "fastMode") return "Ctrl+F";
  if (id === "mode" || id === "permissionMode" || id === "approvals") return "Shift+Tab";
  return "";
}

function OptionSelectChip({
  option,
  onChange,
  open,
  onOpenChange,
}: {
  option: SessionOption;
  onChange: (id: string, value: OptionValue) => void;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const value = String(option.value ?? "");
  const choices = option.choices?.length
    ? option.choices
    : (value ? [{ value, label: value }] : []);
  const current = choices.find((c) => c.value === value)?.label ?? (value || option.label);
  const title = [option.description, optionHint(option.id)].filter(Boolean).join(" · ");
  return (
    <Select.Root
      value={value}
      disabled={option.disabled || !choices.length}
      open={open}
      onOpenChange={(next) => onOpenChange(next)}
      onValueChange={(v) => onChange(option.id, String(v))}
    >
      <Select.Trigger className="chip option-chip select-trigger" title={title || option.label}>
        <span className="option-label">{option.label}</span>
        <span className="select-value">{current}</span>
        <Select.Icon className="chev"><Chevron /></Select.Icon>
      </Select.Trigger>
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

function OptionToggleChip({ option, onChange }: { option: SessionOption; onChange: (id: string, value: OptionValue) => void }) {
  const title = [option.description, optionHint(option.id)].filter(Boolean).join(" · ");
  return (
    <label className={"switch-row option-toggle" + (option.disabled ? " disabled" : "")} title={title || option.label}>
      <Switch.Root
        checked={Boolean(option.value)}
        disabled={option.disabled}
        onCheckedChange={(v) => onChange(option.id, Boolean(v))}
        className="switch"
      >
        <Switch.Thumb className="switch-thumb" />
      </Switch.Root>
      {option.label}
    </label>
  );
}

function OptionsToolbar({
  options,
  onChange,
  openOptionId,
  setOpenOptionId,
}: {
  options: SessionOption[];
  onChange: (id: string, value: OptionValue) => void;
  openOptionId: string | null;
  setOpenOptionId: (id: string | null) => void;
}) {
  if (!options.length) return null;
  return (
    <div className="options-toolbar">
      {options.map((o) => o.kind === "toggle"
        ? <OptionToggleChip key={o.id} option={o} onChange={onChange} />
        : (
          <OptionSelectChip
            key={o.id}
            option={o}
            onChange={onChange}
            open={openOptionId === o.id}
            onOpenChange={(open) => setOpenOptionId(open ? o.id : null)}
          />
        ))}
    </div>
  );
}

function StatusStrip({ options }: { options: SessionOption[] }) {
  const parts = ["model", "effort", "thinking", "mode", "permissionMode", "approvals"]
    .map((id) => options.find((o) => o.id === id))
    .filter(Boolean)
    .map((o) => {
      const opt = o!;
      const value = opt.kind === "toggle"
        ? (opt.value ? "on" : "off")
        : opt.choices?.find((c) => c.value === opt.value)?.label ?? String(opt.value || "");
      return value ? `${opt.label}: ${value}` : "";
    })
    .filter(Boolean);
  if (!parts.length) return null;
  return <div className="status-strip">{parts.join(" · ")}</div>;
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
        <StatusStrip options={options} />
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
        <div className="toolbar">
          <div className="tb-group">
            <ProviderSelect providers={providers} value={provider} onChange={changeProvider} />
            <CwdPopover cwd={cwd} onChange={changeCwd} onCommit={commitCwd} />
          </div>
          <OptionsToolbar options={options} onChange={setLocalOption} openOptionId={openOptionId} setOpenOptionId={setOpenOptionId} />
          <div className="tb-spacer" />
          <label className="switch-row">
            <Switch.Root checked={autoApprove} onCheckedChange={setAutoApprove} className="switch">
              <Switch.Thumb className="switch-thumb" />
            </Switch.Root>
            auto-approve
          </label>
          <button className="send" type="button" aria-label="Start" disabled={!prompt.trim()} onClick={submit}>
            <ArrowUp />
          </button>
        </div>
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
          <StatusStrip options={options} />
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
          <div className="chat-toolbar">
            <OptionsToolbar options={options} onChange={setOption} openOptionId={openOptionId} setOpenOptionId={setOpenOptionId} />
            <div className="tb-spacer" />
            <div className="chat-actions">
              {running ? <button id="stop-btn" type="button" onClick={stop}>Stop</button> : null}
              <button className="send" type="button" aria-label="Send" disabled={!text.trim()} onClick={submit}>
                <ArrowUp />
              </button>
            </div>
          </div>
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
