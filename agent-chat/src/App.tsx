import { createContext, useContext, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Select } from "@base-ui-components/react/select";
import { Switch } from "@base-ui-components/react/switch";
import { Popover } from "@base-ui-components/react/popover";
import { useSession, type Block, type Provider, type SessionState } from "./session";
import { renderMd } from "./md";

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

function CwdPopover({ cwd, onChange }: { cwd: string; onChange: (v: string) => void }) {
  return (
    <Popover.Root>
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
              onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
            />
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

function Composer() {
  const { providers, defaultCwd, start } = useCtx();
  const [provider, setProvider] = useState(() => localStorage.getItem("agentui.provider") || "claude");
  const [cwd, setCwd] = useState(() => localStorage.getItem("agentui.cwd") || "");
  const [prompt, setPrompt] = useState("");
  const [autoApprove, setAutoApprove] = useState(true);
  const taRef = useAutoGrow(prompt, 300);

  useEffect(() => { if (!cwd && defaultCwd) setCwd(defaultCwd); }, [defaultCwd, cwd]);
  useEffect(() => {
    if (providers.length && !providers.some((p) => p.id === provider)) setProvider(providers[0].id);
  }, [providers, provider]);

  const submit = () => {
    const text = prompt.trim();
    if (!text) return;
    localStorage.setItem("agentui.provider", provider);
    localStorage.setItem("agentui.cwd", cwd);
    start({ provider, cwd, prompt: text, autoApprove });
    setPrompt("");
  };
  const changeCwd = (v: string) => { setCwd(v); localStorage.setItem("agentui.cwd", v.trim()); };
  const changeProvider = (v: string) => { setProvider(v); localStorage.setItem("agentui.provider", v); };

  return (
    <section id="composer-view">
      <h1>What should the agent do?</h1>
      <div id="composer-card">
        <textarea
          ref={taRef}
          id="prompt-input"
          placeholder="Describe a task or ask a question…"
          value={prompt}
          autoFocus
          onChange={(e) => setPrompt(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); } }}
        />
        <div className="toolbar">
          <div className="tb-group">
            <ProviderSelect providers={providers} value={provider} onChange={changeProvider} />
            <CwdPopover cwd={cwd} onChange={changeCwd} />
          </div>
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
      <div id="composer-hint">Enter to start · Shift+Enter for newline</div>
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
  const { session, blocks, reply, stop } = useCtx();
  const [text, setText] = useState("");
  const taRef = useAutoGrow(text, 200);
  const scrollRef = useRef<HTMLDivElement>(null);
  const stickRef = useRef(true);

  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (el && stickRef.current) el.scrollTop = el.scrollHeight;
  }, [blocks]);

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
          <textarea
            ref={taRef}
            id="chat-input"
            placeholder="Reply…"
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); } }}
          />
          <div className="chat-actions">
            {session?.status === "running" ? <button id="stop-btn" type="button" onClick={stop}>Stop</button> : null}
            <button className="send" type="button" aria-label="Send" disabled={!text.trim()} onClick={submit}>
              <ArrowUp />
            </button>
          </div>
        </div>
      </div>
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
