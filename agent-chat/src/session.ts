// Client-side session state: one WebSocket, one session per page.
import { useCallback, useEffect, useRef, useState } from "react";

export type AgentEvent =
  | { kind: "meta"; model?: string; providerSessionId?: string }
  | { kind: "user"; text: string }
  | { kind: "status"; text: string }
  | { kind: "delta"; text: string }
  | { kind: "assistant"; text: string }
  | { kind: "thinking"; text: string }
  | { kind: "tool-start"; toolId: string; name: string; detail?: string }
  | { kind: "tool-end"; toolId: string; name?: string; detail?: string; ok?: boolean }
  | { kind: "done"; stats?: string }
  | { kind: "error"; message: string };

export type Block =
  | { kind: "user"; text: string }
  | { kind: "assistant"; text: string; open: boolean }
  | { kind: "thinking"; text: string; open: boolean }
  | { kind: "tool"; toolId: string; name: string; detail?: string; status: "running" | "ok" | "fail"; out?: string }
  | { kind: "status"; text: string }
  | { kind: "error"; text: string }
  | { kind: "footer"; text: string };

export interface Provider { id: string; label: string; }
export interface SessionSummary { id: string; provider: string; cwd: string; title: string; status: string; }

function closeStreaming(blocks: Block[]): Block[] {
  const last = blocks[blocks.length - 1];
  if (last && (last.kind === "assistant" || last.kind === "thinking") && last.open) {
    return [...blocks.slice(0, -1), { ...last, open: false }];
  }
  return blocks;
}

export function foldEvent(blocks: Block[], evt: AgentEvent): Block[] {
  const last = blocks[blocks.length - 1];
  switch (evt.kind) {
    case "user":
      return [...closeStreaming(blocks), { kind: "user", text: evt.text }];
    case "delta":
      if (last && last.kind === "assistant" && last.open) {
        return [...blocks.slice(0, -1), { ...last, text: last.text + evt.text }];
      }
      return [...closeStreaming(blocks), { kind: "assistant", text: evt.text, open: true }];
    case "assistant":
      if (last && last.kind === "assistant" && last.open) {
        return [...blocks.slice(0, -1), { ...last, text: evt.text, open: false }];
      }
      return [...closeStreaming(blocks), { kind: "assistant", text: evt.text, open: false }];
    case "thinking":
      if (last && last.kind === "thinking" && last.open) {
        return [...blocks.slice(0, -1), { ...last, text: last.text + evt.text }];
      }
      return [...closeStreaming(blocks), { kind: "thinking", text: evt.text, open: true }];
    case "tool-start":
      return [...closeStreaming(blocks), { kind: "tool", toolId: evt.toolId, name: evt.name || "tool", detail: evt.detail, status: "running" }];
    case "tool-end":
      return blocks.map((b) =>
        b.kind === "tool" && b.toolId === evt.toolId
          ? { ...b, status: evt.ok === false ? "fail" : "ok", out: evt.detail || b.out }
          : b,
      );
    case "done": {
      const closed = closeStreaming(blocks);
      return evt.stats ? [...closed, { kind: "footer", text: evt.stats }] : closed;
    }
    case "error":
      return [...closeStreaming(blocks), { kind: "error", text: evt.message }];
    case "status":
      return [...closeStreaming(blocks), { kind: "status", text: evt.text }];
    default:
      return blocks;
  }
}

interface Hello { providers: Provider[]; defaultCwd: string; }

export interface SessionState {
  ready: boolean;
  providers: Provider[];
  defaultCwd: string;
  phase: "composer" | "chat";
  session: SessionSummary | null;
  blocks: Block[];
  start(opts: { provider: string; cwd: string; prompt: string; autoApprove: boolean }): void;
  reply(text: string): void;
  stop(): void;
}

const routedSessionId = (location.pathname.match(/^\/s\/([\w-]+)/) || [])[1] || null;

export function useSession(): SessionState {
  const [ready, setReady] = useState(false);
  const [providers, setProviders] = useState<Provider[]>([]);
  const [defaultCwd, setDefaultCwd] = useState("");
  const [phase, setPhase] = useState<"composer" | "chat">(routedSessionId ? "chat" : "composer");
  const [session, setSession] = useState<SessionSummary | null>(null);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const wsRef = useRef<WebSocket | null>(null);
  const sessionIdRef = useRef<string | null>(routedSessionId);

  const sendRaw = useCallback((obj: unknown) => {
    const ws = wsRef.current;
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
  }, []);

  useEffect(() => {
    let closed = false;
    const connect = () => {
      const ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
      wsRef.current = ws;
      ws.onopen = () => {
        if (sessionIdRef.current) sendRaw({ op: "subscribe", sessionId: sessionIdRef.current });
      };
      ws.onmessage = (e) => {
        const msg = JSON.parse(e.data);
        switch (msg.kind) {
          case "hello": {
            const h = msg as Hello & { kind: string };
            setProviders(h.providers);
            setDefaultCwd(h.defaultCwd);
            setReady(true);
            break;
          }
          case "session-created":
            sessionIdRef.current = msg.session.id;
            history.replaceState(null, "", "/s/" + msg.session.id);
            document.title = msg.session.title || "cmux agent";
            setSession(msg.session);
            setBlocks([]);
            setPhase("chat");
            break;
          case "history":
            sessionIdRef.current = msg.session.id;
            document.title = msg.session.title || "cmux agent";
            setSession(msg.session);
            setBlocks((msg.events as AgentEvent[]).reduce(foldEvent, [] as Block[]));
            setPhase("chat");
            break;
          case "no-session":
            history.replaceState(null, "", "/");
            sessionIdRef.current = null;
            setSession(null);
            setPhase("composer");
            break;
          case "session-status":
            if (msg.sessionId === sessionIdRef.current) {
              setSession((s) => (s ? { ...s, status: msg.status } : s));
            }
            break;
          case "event":
            if (msg.sessionId === sessionIdRef.current) setBlocks((bs) => foldEvent(bs, msg.evt));
            break;
        }
      };
      ws.onclose = () => { if (!closed) setTimeout(connect, 800); };
    };
    connect();
    return () => { closed = true; wsRef.current?.close(); };
  }, [sendRaw]);

  const start = useCallback((opts: { provider: string; cwd: string; prompt: string; autoApprove: boolean }) => {
    sendRaw({ op: "start", ...opts });
  }, [sendRaw]);
  const reply = useCallback((text: string) => {
    if (sessionIdRef.current) sendRaw({ op: "send", sessionId: sessionIdRef.current, prompt: text });
  }, [sendRaw]);
  const stop = useCallback(() => {
    if (sessionIdRef.current) sendRaw({ op: "stop", sessionId: sessionIdRef.current });
  }, [sendRaw]);

  return { ready, providers, defaultCwd, phase, session, blocks, start, reply, stop };
}
