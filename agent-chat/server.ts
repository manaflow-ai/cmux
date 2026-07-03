import type { AgentEvent, Adapter, ProviderDef, SessionCtx, SessionStatus } from "./types";
import { claudeAdapter } from "./adapters/claude";
import { codexAdapter } from "./adapters/codex";
import { piAdapter } from "./adapters/pi";
import { makeAcpAdapter } from "./adapters/acp";
import { resolveGhosttyTheme } from "./theme";
import { readFileSync } from "node:fs";

const PORT = Number(process.env.CMUX_AGENT_UI_PORT ?? 7739);

// Under launchd the PATH is minimal; make sure the agent CLIs resolve.
{
  const home = process.env.HOME ?? "";
  const extra = [`${home}/.local/bin`, `${home}/.bun/bin`, "/opt/homebrew/bin", "/usr/local/bin"];
  const cur = (process.env.PATH ?? "").split(":");
  process.env.PATH = [...extra.filter((p) => !cur.includes(p)), ...cur].join(":");
}
const ROOT = import.meta.dir;
const DEFAULT_CWD = `${ROOT}/scratch`;

const PROVIDERS: ProviderDef[] = [
  { id: "claude", label: "Claude Code", adapter: "claude" },
  { id: "codex", label: "Codex", adapter: "codex" },
  { id: "opencode", label: "OpenCode", adapter: "acp", cmd: ["opencode", "acp"] },
  { id: "pi", label: "pi", adapter: "pi" },
  {
    id: "gemini",
    label: "Gemini",
    adapter: "acp",
    cmd: ["gemini", "--acp", "--model", "gemini-3.1-pro-preview"],
    autoApproveArgs: ["--yolo"],
  },
];

const adapters = new Map<string, Adapter>();
for (const def of PROVIDERS) {
  if (def.adapter === "claude") adapters.set(def.id, claudeAdapter);
  else if (def.adapter === "codex") adapters.set(def.id, codexAdapter);
  else if (def.adapter === "pi") adapters.set(def.id, piAdapter);
  else if (def.adapter === "acp") adapters.set(def.id, makeAcpAdapter(def));
}

interface Session extends SessionCtx {
  adapter: Adapter;
  sockets: Set<Bun.ServerWebSocket<WsData>>;
  createdAt: number;
}
interface WsData {
  subscribed: string | null;
}

const sessions = new Map<string, Session>();
const allSockets = new Set<Bun.ServerWebSocket<WsData>>();

function sessionSummary(s: Session) {
  return { id: s.id, provider: s.provider, cwd: s.cwd, title: s.title, status: s.status, createdAt: s.createdAt };
}

function broadcastSessions() {
  const payload = JSON.stringify({
    kind: "sessions",
    sessions: [...sessions.values()].sort((a, b) => b.createdAt - a.createdAt).map(sessionSummary),
  });
  for (const ws of allSockets) ws.send(payload);
}

function createSession(provider: string, cwd: string, autoApprove: boolean, title: string): Session {
  const adapter = adapters.get(provider);
  if (!adapter) throw new Error(`unknown provider: ${provider}`);
  const id = crypto.randomUUID().slice(0, 8);
  const sess: Session = {
    id,
    provider,
    cwd,
    title,
    autoApprove,
    status: "idle",
    events: [],
    internal: {},
    adapter,
    sockets: new Set(),
    createdAt: Date.now(),
    emit(evt: AgentEvent) {
      sess.events.push(evt);
      const payload = JSON.stringify({ kind: "event", sessionId: id, evt });
      for (const ws of sess.sockets) ws.send(payload);
    },
    setStatus(status: SessionStatus) {
      if (sess.status === status) return;
      sess.status = status;
      const payload = JSON.stringify({ kind: "session-status", sessionId: id, status });
      for (const ws of sess.sockets) ws.send(payload);
      broadcastSessions();
    },
  };
  sessions.set(id, sess);
  broadcastSessions();
  return sess;
}

function sendPrompt(sess: Session, prompt: string) {
  sess.emit({ kind: "user", text: prompt });
  Promise.resolve(sess.adapter.send(sess, prompt)).catch((err) => {
    sess.emit({ kind: "error", message: String(err) });
    sess.setStatus("idle");
  });
}

// Inject the resolved Ghostty theme as CSS variables at serve time so the
// page paints with the terminal's colors on first frame. `?transparent=1` is
// appended by openers that created the browser surface with
// transparent_background, so only genuinely transparent surfaces get an alpha
// body; `?opacity=` is a dogfood override.
function renderPage(url: URL): string {
  const theme = resolveGhosttyTheme();
  const transparent = url.searchParams.get("transparent") === "1";
  const override = parseFloat(url.searchParams.get("opacity") ?? "");
  const opacity = transparent ? (Number.isNaN(override) ? theme.opacity : override) : 1;
  const n = parseInt(theme.background.slice(1), 16);
  const rgb = `${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}`;
  const accent = theme.isLight ? "#3b5bdb" : "#7aa2f7";
  const green = theme.isLight ? "#2b8a3e" : "#6fbf82";
  const red = theme.isLight ? "#c92a2a" : "#e06c75";
  const amber = theme.isLight ? "#e8590c" : "#d8a657";
  // In opaque mode html paints the same solid bg as body, so nothing behind
  // the webview (a terminal surface) can composite through the transparent
  // document root. In transparent mode html stays clear on purpose so
  // background-opacity/blur show through.
  const bgHtml = transparent ? "transparent" : theme.background;
  const css = `:root { --bg: ${theme.background}; --fg: ${theme.foreground}; ` +
    `--bg-body: rgba(${rgb}, ${opacity}); --bg-html: ${bgHtml}; --accent: ${accent}; ` +
    `--green: ${green}; --red: ${red}; --amber: ${amber}; }`;
  // Shell: theme vars first (so the first paint is the terminal bg), the
  // static stylesheet, a mount point, and the bundled React app (Base UI).
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cmux agent</title>
<link rel="stylesheet" href="/app.css">
<style>${css}</style>
</head><body>
<div id="root"></div>
<script type="module" src="/app.js"></script>
</body></html>`;
}

// Bundle the React + Base UI frontend with Bun. Built once at startup and
// cached; rebuilt on each request only when CMUX_AGENT_UI_CACHE != "1" (dev).
let bundleCache: string | null = null;
async function buildBundle(): Promise<string> {
  if (bundleCache && process.env.CMUX_AGENT_UI_CACHE === "1") return bundleCache;
  const out = await Bun.build({
    entrypoints: [`${ROOT}/src/main.tsx`],
    target: "browser",
    minify: true,
    define: { "process.env.NODE_ENV": '"production"' },
  });
  if (!out.success) {
    const msg = out.logs.map((l) => String(l)).join("\n");
    throw new Error("bundle failed:\n" + msg);
  }
  bundleCache = await out.outputs[0].text();
  return bundleCache;
}

const server = Bun.serve<WsData>({
  port: PORT,
  async fetch(req, srv) {
    const url = new URL(req.url);
    if (url.pathname === "/ws") {
      return srv.upgrade(req, { data: { subscribed: null } })
        ? undefined
        : new Response("upgrade failed", { status: 400 });
    }
    if (url.pathname === "/healthz") return new Response("ok");
    if (url.pathname === "/app.js") {
      try {
        return new Response(await buildBundle(), {
          headers: { "content-type": "application/javascript; charset=utf-8" },
        });
      } catch (err) {
        return new Response(`console.error(${JSON.stringify(String(err))})`, {
          status: 500,
          headers: { "content-type": "application/javascript; charset=utf-8" },
        });
      }
    }
    if (url.pathname === "/app.css") {
      return new Response(Bun.file(`${ROOT}/public/app.css`), {
        headers: { "content-type": "text/css; charset=utf-8" },
      });
    }
    if (url.pathname === "/api/theme") return Response.json(resolveGhosttyTheme());
    // REST for the CLI: create a session (optionally with a first prompt) and
    // get back its id/url; list sessions.
    if (url.pathname === "/api/sessions" && req.method === "POST") {
      const body = await req.json().catch(() => ({}));
      const provider = String(body.provider ?? "claude");
      const prompt = String(body.prompt ?? "").trim();
      const cwd = String(body.cwd || DEFAULT_CWD);
      const title = prompt ? (prompt.length > 64 ? prompt.slice(0, 64) + "…" : prompt) : `${provider} chat`;
      let sess: Session;
      try {
        sess = createSession(provider, cwd, body.autoApprove !== false, title);
      } catch (err) {
        return Response.json({ error: String(err) }, { status: 400 });
      }
      if (prompt) sendPrompt(sess, prompt);
      return Response.json({ id: sess.id, url: `http://127.0.0.1:${PORT}/s/${sess.id}` });
    }
    if (url.pathname === "/api/sessions" && req.method === "GET") {
      return Response.json([...sessions.values()].sort((a, b) => b.createdAt - a.createdAt).map(sessionSummary));
    }
    return new Response(renderPage(url), { headers: { "content-type": "text/html; charset=utf-8" } });
  },
  websocket: {
    open(ws) {
      allSockets.add(ws);
      ws.send(JSON.stringify({
        kind: "hello",
        providers: PROVIDERS.map((p) => ({ id: p.id, label: p.label })),
        defaultCwd: process.env.CMUX_AGENT_UI_CWD ?? DEFAULT_CWD,
      }));
      ws.send(JSON.stringify({
        kind: "sessions",
        sessions: [...sessions.values()].sort((a, b) => b.createdAt - a.createdAt).map(sessionSummary),
      }));
    },
    close(ws) {
      allSockets.delete(ws);
      const sid = ws.data.subscribed;
      if (sid) sessions.get(sid)?.sockets.delete(ws);
    },
    message(ws, raw) {
      let msg: any;
      try {
        msg = JSON.parse(String(raw));
      } catch {
        return;
      }
      try {
        handleMessage(ws, msg);
      } catch (err) {
        ws.send(JSON.stringify({ kind: "error", message: String(err) }));
      }
    },
  },
});

function handleMessage(ws: Bun.ServerWebSocket<WsData>, msg: any) {
  switch (msg.op) {
    case "start": {
      const prompt = String(msg.prompt ?? "").trim();
      if (!prompt) return;
      const cwd = String(msg.cwd || DEFAULT_CWD);
      const title = prompt.length > 64 ? prompt.slice(0, 64) + "…" : prompt;
      const sess = createSession(String(msg.provider), cwd, Boolean(msg.autoApprove), title);
      subscribe(ws, sess);
      ws.send(JSON.stringify({ kind: "session-created", session: sessionSummary(sess) }));
      sendPrompt(sess, prompt);
      break;
    }
    case "send": {
      const sess = sessions.get(String(msg.sessionId));
      const prompt = String(msg.prompt ?? "").trim();
      if (!sess || !prompt) return;
      sendPrompt(sess, prompt);
      break;
    }
    case "subscribe": {
      const sess = sessions.get(String(msg.sessionId));
      if (!sess) {
        ws.send(JSON.stringify({ kind: "no-session", sessionId: msg.sessionId }));
        return;
      }
      subscribe(ws, sess);
      ws.send(JSON.stringify({
        kind: "history",
        sessionId: sess.id,
        session: sessionSummary(sess),
        events: sess.events,
      }));
      break;
    }
    case "stop": {
      const sess = sessions.get(String(msg.sessionId));
      sess?.adapter.stop(sess);
      break;
    }
    case "delete": {
      const sess = sessions.get(String(msg.sessionId));
      if (!sess) return;
      sess.adapter.dispose(sess);
      sessions.delete(sess.id);
      broadcastSessions();
      break;
    }
  }
}

function subscribe(ws: Bun.ServerWebSocket<WsData>, sess: Session) {
  const prev = ws.data.subscribed;
  if (prev) sessions.get(prev)?.sockets.delete(ws);
  ws.data.subscribed = sess.id;
  sess.sockets.add(ws);
}

process.on("SIGINT", () => {
  for (const sess of sessions.values()) sess.adapter.dispose(sess);
  process.exit(0);
});

// Warm the bundle so the first page load doesn't pay the build cost, and so a
// build error surfaces at startup rather than as a blank page.
buildBundle().then(
  () => console.log("bundle ready"),
  (err) => console.error(String(err)),
);

console.log(`cmux-agent-ui listening on http://127.0.0.1:${server.port}`);
