import type {
  Adapter,
  AgentEvent,
  CommandEntry,
  CommandTrigger,
  OptionValue,
  ProviderCapabilities,
  ProviderDef,
  SessionCtx,
  SessionOption,
  SessionStatus,
} from "./types";
import { claudeAdapter } from "./adapters/claude";
import { codexAdapter } from "./adapters/codex";
import { piAdapter } from "./adapters/pi";
import { makeAcpAdapter } from "./adapters/acp";
import { resolveGhosttyTheme } from "./theme";
import { existsSync } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { extname, isAbsolute, join, relative, resolve } from "node:path";

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
const ICON_ROOT = resolve(ROOT, "../Assets.xcassets/AgentIcons");
const CATALOG_TTL_MS = 10 * 60_000;
const FILES_TTL_MS = 30_000;
const FILES_LIMIT = 5_000;

const PROVIDERS: ProviderDef[] = [
  { id: "claude", label: "Claude Code", adapter: "claude", cmd: ["claude"], installCommand: "npm i -g @anthropic-ai/claude-code" },
  { id: "codex", label: "Codex", adapter: "codex", cmd: ["codex"], installCommand: "npm i -g @openai/codex" },
  { id: "opencode", label: "OpenCode", adapter: "acp", cmd: ["opencode", "acp"], installCommand: "npm i -g opencode-ai" },
  { id: "pi", label: "pi", adapter: "pi", cmd: ["pi"], installCommand: "npm i -g @mariozechner/pi" },
  {
    id: "gemini",
    label: "Gemini",
    adapter: "acp",
    cmd: ["gemini", "--acp", "--model", "gemini-3.1-pro-preview"],
    autoApproveArgs: ["--yolo"],
    installCommand: "npm i -g @google/gemini-cli",
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
const optionCatalog = new Map<string, {
  options: SessionOption[];
  fetchedAt: number;
  refreshing?: Promise<SessionOption[]>;
}>();
const commandCatalog = new Map<string, {
  groups: { trigger: CommandTrigger; commands: CommandEntry[] }[];
  fetchedAt: number;
  refreshing?: Promise<{ trigger: CommandTrigger; commands: CommandEntry[] }[]>;
}>();
const fileCatalog = new Map<string, { files: string[]; fetchedAt: number; refreshing?: Promise<string[]> }>();
const keyConfig = await readKeyConfig();

function sessionSummary(s: Session) {
  return {
    id: s.id,
    provider: s.provider,
    cwd: s.cwd,
    title: s.title,
    status: s.status,
    createdAt: s.createdAt,
    capabilities: capabilitiesFor(s.provider),
  };
}

function capabilitiesFor(provider: string): ProviderCapabilities {
  return adapters.get(provider)?.capabilities ?? { options: [], triggers: [] };
}

function capabilitiesMap(): Record<string, ProviderCapabilities> {
  return Object.fromEntries(PROVIDERS.map((p) => [p.id, capabilitiesFor(p.id)]));
}

function providerInfo(p: ProviderDef) {
  return {
    id: p.id,
    label: p.label,
    // Bun.which ignores runtime process.env.PATH mutations (it reads the
    // process's original environ), so pass the prepended PATH explicitly or
    // every provider reads as uninstalled under launchd's minimal PATH.
    installed: Boolean(Bun.which(p.cmd?.[0] ?? p.id, { PATH: process.env.PATH })),
    installCommand: p.installCommand,
    ...(providerIconInfo.get(p.id) ?? {}),
  };
}

function broadcastSessions() {
  const payload = JSON.stringify({
    kind: "sessions",
    sessions: [...sessions.values()].sort((a, b) => b.createdAt - a.createdAt).map(sessionSummary),
  });
  for (const ws of allSockets) ws.send(payload);
}

function createSession(
  provider: string,
  cwd: string,
  autoApprove: boolean,
  title: string,
  startOptions: Record<string, OptionValue> = {},
): Session {
  const adapter = adapters.get(provider);
  if (!adapter) throw new Error(`unknown provider: ${provider}`);
  const id = crypto.randomUUID().slice(0, 8);
  const sess: Session = {
    id,
    provider,
    cwd,
    title,
    autoApprove,
    startOptions,
    seedOptions: optionCatalog.get(provider)?.options,
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

function refreshSession(sess: Session) {
  Promise.resolve(sess.adapter.refreshOptions?.(sess)).catch((err) => {
    sess.emit({ kind: "error", message: String(err) });
  });
}

async function forkSession(source: Session): Promise<Session> {
  if (!source.adapter.forkSession) throw new Error(`${source.provider} does not support fork`);
  await assertCwd(source.cwd);
  const fork = createSession(source.provider, source.cwd, source.autoApprove, source.title, { ...source.startOptions });
  fork.events = source.events.slice();
  try {
    await source.adapter.forkSession(source, fork);
    refreshSession(fork);
    return fork;
  } catch (err) {
    fork.adapter.dispose(fork);
    sessions.delete(fork.id);
    broadcastSessions();
    throw err;
  }
}

async function checkCwd(cwd: string): Promise<{ ok: boolean; message?: string }> {
  try {
    const s = await stat(cwd);
    if (s.isDirectory()) return { ok: true };
  } catch {
    // Fall through to the stable user-facing message.
  }
  return { ok: false, message: `working directory does not exist: ${cwd}` };
}

async function assertCwd(cwd: string) {
  const res = await checkCwd(cwd);
  if (!res.ok) throw new Error(res.message);
}

function parseOptions(raw: unknown): Record<string, OptionValue> {
  if (!raw || typeof raw !== "object") return {};
  const out: Record<string, OptionValue> = {};
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof v === "string" || typeof v === "boolean") out[k] = v;
  }
  return out;
}

function applyAutoApproveDefaults(provider: string, autoApprove: boolean, raw: Record<string, OptionValue>): Record<string, OptionValue> {
  const out = { ...raw };
  if (provider === "claude") {
    if (out.permissionMode === undefined) out.permissionMode = autoApprove ? "acceptEdits" : "default";
  } else if (provider === "codex") {
    if (out.approvals === undefined) out.approvals = autoApprove ? "never" : "on-request";
    if (out.sandbox === undefined) out.sandbox = autoApprove ? "workspace-write" : "read-only";
  } else if (provider === "opencode" || provider === "gemini") {
    if (out.autoApprove === undefined) out.autoApprove = autoApprove;
  }
  return out;
}

async function sanitizeStartOptions(provider: string, cwd: string, raw: Record<string, OptionValue>): Promise<Record<string, OptionValue>> {
  if (!Object.keys(raw).length) return raw;
  const catalog = await catalogOptions(provider, cwd, { refreshMissing: false });
  return filterOptions(raw, catalog);
}

function filterOptions(raw: Record<string, OptionValue>, catalog: SessionOption[]): Record<string, OptionValue> {
  const byId = new Map(catalog.map((o) => [o.id, o]));
  const out: Record<string, OptionValue> = {};
  for (const [id, value] of Object.entries(raw)) {
    const option = byId.get(id);
    if (!option) continue;
    if (option.kind === "toggle" && typeof value === "boolean") out[id] = value;
    if (option.kind === "select" && typeof value === "string" && option.choices?.some((c) => c.value === value)) out[id] = value;
  }
  return out;
}

function fallbackOptions(provider: string): SessionOption[] {
  return adapters.get(provider)?.capabilities?.options ?? [];
}

function shouldRefreshCatalog(provider: string): boolean {
  const entry = optionCatalog.get(provider);
  return !entry || Date.now() - entry.fetchedAt > CATALOG_TTL_MS;
}

function refreshCatalog(provider: string, cwd: string): Promise<SessionOption[]> {
  const adapter = adapters.get(provider);
  if (!adapter) return Promise.reject(new Error(`unknown provider: ${provider}`));
  const current = optionCatalog.get(provider);
  if (current?.refreshing) return current.refreshing;
  const refreshing = Promise.resolve(adapter.listOptions?.(cwd) ?? adapter.capabilities?.options ?? [])
    .then((options) => {
      optionCatalog.set(provider, { options, fetchedAt: Date.now() });
      return options;
    })
    .catch((err) => {
      if (!optionCatalog.has(provider)) optionCatalog.set(provider, { options: fallbackOptions(provider), fetchedAt: Date.now() });
      throw err;
    })
    .finally(() => {
      const entry = optionCatalog.get(provider);
      if (entry?.refreshing === refreshing) optionCatalog.set(provider, { options: entry.options, fetchedAt: entry.fetchedAt });
    });
  optionCatalog.set(provider, { options: current?.options ?? fallbackOptions(provider), fetchedAt: current?.fetchedAt ?? 0, refreshing });
  return refreshing;
}

async function catalogOptions(provider: string, cwd: string, opts: { refreshMissing?: boolean } = {}): Promise<SessionOption[]> {
  if (!adapters.has(provider)) throw new Error(`unknown provider: ${provider}`);
  const entry = optionCatalog.get(provider);
  if (entry) {
    if (!entry.fetchedAt && entry.refreshing && opts.refreshMissing !== false) {
      try {
        return await entry.refreshing;
      } catch {
        return fallbackOptions(provider);
      }
    }
    if (shouldRefreshCatalog(provider)) refreshCatalog(provider, cwd).catch(() => {});
    return entry.options;
  }
  if (opts.refreshMissing === false) {
    refreshCatalog(provider, cwd).catch(() => {});
    return fallbackOptions(provider);
  }
  try {
    return await refreshCatalog(provider, cwd);
  } catch {
    return fallbackOptions(provider);
  }
}

async function cachedCommands(provider: string, cwd: string): Promise<{ trigger: CommandTrigger; commands: CommandEntry[] }[]> {
  const adapter = adapters.get(provider);
  if (!adapter) throw new Error(`unknown provider: ${provider}`);
  const key = `${provider}:${resolve(cwd || DEFAULT_CWD)}`;
  const entry = commandCatalog.get(key);
  if (entry) {
    if (!entry.fetchedAt && entry.refreshing) return entry.refreshing;
    if (Date.now() - entry.fetchedAt <= CATALOG_TTL_MS) return entry.groups;
    if (entry.refreshing) return entry.groups;
  }
  const refreshing = Promise.resolve(adapter.listCommands?.(cwd) ?? [])
    .then((groups) => {
      commandCatalog.set(key, { groups, fetchedAt: Date.now() });
      return groups;
    })
    .catch((err) => {
      if (!commandCatalog.has(key)) commandCatalog.set(key, { groups: [], fetchedAt: Date.now() });
      throw err;
    })
    .finally(() => {
      const current = commandCatalog.get(key);
      if (current?.refreshing === refreshing) commandCatalog.set(key, { groups: current.groups, fetchedAt: current.fetchedAt });
    });
  commandCatalog.set(key, { groups: entry?.groups ?? [], fetchedAt: entry?.fetchedAt ?? 0, refreshing });
  return refreshing;
}

async function readKeyConfig(): Promise<{ ctrlJ: "newline" | "menu" }> {
  try {
    const text = await Bun.file(resolve(homedir(), ".config/cmux/cmux.json")).text();
    const parsed = JSON.parse(text);
    const value = parsed?.agentChat?.keys?.ctrlJ;
    return { ctrlJ: value === "menu" ? "menu" : "newline" };
  } catch {
    return { ctrlJ: "newline" };
  }
}

async function cachedFiles(cwd: string): Promise<string[]> {
  const key = resolve(cwd || DEFAULT_CWD);
  const entry = fileCatalog.get(key);
  if (entry) {
    if (!entry.fetchedAt && entry.refreshing) return entry.refreshing;
    if (Date.now() - entry.fetchedAt <= FILES_TTL_MS) return entry.files;
    if (!entry.refreshing) {
      const refreshing = loadFiles(key)
        .then((files) => {
          fileCatalog.set(key, { files, fetchedAt: Date.now() });
          return files;
        })
        .catch((err) => {
          console.warn(`file catalog refresh failed for ${key}: ${String(err)}`);
          return entry.files;
        });
      fileCatalog.set(key, { ...entry, refreshing });
    }
    return entry.files;
  }
  const refreshing = loadFiles(key).then((files) => {
    fileCatalog.set(key, { files, fetchedAt: Date.now() });
    return files;
  });
  fileCatalog.set(key, { files: [], fetchedAt: 0, refreshing });
  return refreshing;
}

async function loadFiles(cwd: string): Promise<string[]> {
  try {
    return limitFiles(await gitFiles(cwd));
  } catch {
    return limitFiles(await walkFiles(cwd));
  }
}

function limitFiles(files: string[]): string[] {
  return [...new Set(files.filter(Boolean).map((f) => f.replaceAll("\\", "/")))]
    .filter((f) => !f.startsWith("../") && f !== "..")
    .sort((a, b) => a.localeCompare(b))
    .slice(0, FILES_LIMIT);
}

async function gitFiles(cwd: string): Promise<string[]> {
  const proc = Bun.spawn(["git", "-C", cwd, "ls-files", "--cached", "--others", "--exclude-standard"], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [out, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  if (code !== 0) throw new Error("not a git repo");
  return out.split(/\r?\n/);
}

async function walkFiles(root: string): Promise<string[]> {
  const out: string[] = [];
  const skip = new Set([".git", "node_modules", ".hg", ".svn", ".cache", ".next", "dist", "build"]);
  async function visit(dir: string, depth: number) {
    if (out.length >= FILES_LIMIT || depth > 5) return;
    let entries: Awaited<ReturnType<typeof readdir>>;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const ent of entries) {
      if (out.length >= FILES_LIMIT) return;
      if (ent.name.startsWith(".") || skip.has(ent.name)) continue;
      const full = join(dir, ent.name);
      const rel = relative(root, full).replaceAll("\\", "/");
      if (ent.isDirectory()) {
        await visit(full, depth + 1);
      } else if (ent.isFile()) {
        out.push(rel);
      } else if (ent.isSymbolicLink()) {
        try {
          if ((await stat(full)).isFile()) out.push(rel);
        } catch {
          // Ignore broken links.
        }
      }
    }
  }
  await visit(root, 0);
  return out;
}

function iconFile(provider: string, dark: boolean): string | null {
  const file = provider === "claude" ? "Claude.imageset/Claude@2x.png"
    : provider === "codex" ? `Codex.imageset/${dark ? "Codex-dark@2x.png" : "Codex@2x.png"}`
      : provider === "opencode" ? "OpenCode.imageset/OpenCode@2x.png"
        : provider === "pi" ? "Pi.imageset/Pi.svg"
          : null;
  if (!file) return null;
  const resolved = resolve(ICON_ROOT, file);
  const rel = relative(ICON_ROOT, resolved);
  if (!rel || rel.startsWith("..") || isAbsolute(rel)) return null;
  return existsSync(resolved) ? resolved : null;
}

function iconResponse(url: URL): Response {
  const provider = url.pathname.slice("/icons/".length);
  if (!/^[a-z0-9_-]+$/i.test(provider)) return new Response("not found", { status: 404 });
  const file = iconFile(provider, url.searchParams.get("dark") === "1");
  if (!file) return new Response("not found", { status: 404 });
  const type = extname(file) === ".svg" ? "image/svg+xml" : "image/png";
  return new Response(Bun.file(file), {
    headers: {
      "content-type": type,
      "cache-control": "public, max-age=31536000, immutable",
    },
  });
}

const providerIconInfo = new Map(PROVIDERS.map((p) => {
  const iconUrl = iconFile(p.id, false) ? `/icons/${p.id}` : undefined;
  const iconDarkUrl = p.id === "codex" && iconFile(p.id, true) ? `/icons/${p.id}?dark=1` : undefined;
  return [p.id, { ...(iconUrl ? { iconUrl } : {}), ...(iconDarkUrl ? { iconDarkUrl } : {}) }];
}));

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
    if (url.pathname.startsWith("/icons/")) return iconResponse(url);
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
        await assertCwd(cwd);
        const autoApprove = body.autoApprove !== false;
        const options = applyAutoApproveDefaults(provider, autoApprove, parseOptions(body.options));
        sess = createSession(provider, cwd, autoApprove, title, await sanitizeStartOptions(provider, cwd, options));
      } catch (err) {
        return Response.json({ error: String(err) }, { status: 400 });
      }
      refreshSession(sess);
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
        providers: PROVIDERS.map(providerInfo),
        capabilities: capabilitiesMap(),
        defaultCwd: process.env.CMUX_AGENT_UI_CWD ?? DEFAULT_CWD,
        keys: keyConfig,
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
        sendWsError(ws, String(msg.op ?? ""), err);
      }
    },
  },
});

function sendWsError(ws: Bun.ServerWebSocket<WsData>, op: string, err: unknown) {
  ws.send(JSON.stringify({ kind: "error", op, message: String(err) }));
}

function handleMessage(ws: Bun.ServerWebSocket<WsData>, msg: any) {
  switch (msg.op) {
    case "start": {
      const prompt = String(msg.prompt ?? "").trim();
      if (!prompt) return;
      const cwd = String(msg.cwd || DEFAULT_CWD);
      const title = prompt.length > 64 ? prompt.slice(0, 64) + "…" : prompt;
      const provider = String(msg.provider);
      const autoApprove = msg.autoApprove !== false;
      const rawOptions = applyAutoApproveDefaults(provider, autoApprove, parseOptions(msg.options));
      Promise.resolve(assertCwd(cwd).then(() => sanitizeStartOptions(provider, cwd, rawOptions))).then((options) => {
        const sess = createSession(provider, cwd, autoApprove, title, options);
        subscribe(ws, sess);
        ws.send(JSON.stringify({ kind: "session-created", session: sessionSummary(sess) }));
        refreshSession(sess);
        sendPrompt(sess, prompt);
      }).catch((err) => {
        sendWsError(ws, "start", err);
      });
      break;
    }
    case "check-cwd": {
      const cwd = String(msg.cwd || DEFAULT_CWD);
      Promise.resolve(checkCwd(cwd))
        .then((res) => ws.send(JSON.stringify({ kind: "cwd-check", cwd, ...res })))
        .catch((err) => ws.send(JSON.stringify({ kind: "cwd-check", cwd, ok: false, message: String(err) })));
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
      refreshSession(sess);
      break;
    }
    case "stop": {
      const sess = sessions.get(String(msg.sessionId));
      sess?.adapter.stop(sess);
      break;
    }
    case "set-option": {
      const sess = sessions.get(String(msg.sessionId));
      const id = String(msg.id ?? "");
      const value = msg.value;
      if (!sess || !id || (typeof value !== "string" && typeof value !== "boolean")) return;
      Promise.resolve(sess.adapter.setOption(sess, id, value)).catch((err) => {
        sess.emit({ kind: "error", message: String(err) });
      });
      break;
    }
    case "fork": {
      const sess = sessions.get(String(msg.sessionId));
      if (!sess) return;
      Promise.resolve(forkSession(sess))
        .then((fork) => ws.send(JSON.stringify({ kind: "session-forked", session: sessionSummary(fork) })))
        .catch((err) => sess.emit({ kind: "error", message: String(err) }));
      break;
    }
    case "list-options": {
      const provider = String(msg.provider ?? "");
      if (!adapters.has(provider)) {
        sendWsError(ws, "list-options", `unknown provider: ${provider}`);
        return;
      }
      const cwd = String(msg.cwd || DEFAULT_CWD);
      Promise.resolve(catalogOptions(provider, cwd))
        .then((options) => ws.send(JSON.stringify({ kind: "options-list", provider, options })))
        .catch((err) => sendWsError(ws, "list-options", err));
      break;
    }
    case "list-commands": {
      const provider = String(msg.provider ?? "");
      const adapter = adapters.get(provider);
      if (!adapter) {
        sendWsError(ws, "list-commands", `unknown provider: ${provider}`);
        return;
      }
      const cwd = String(msg.cwd || DEFAULT_CWD);
      Promise.resolve(cachedCommands(provider, cwd))
        .then((groups) => ws.send(JSON.stringify({ kind: "commands-list", provider, groups })))
        .catch((err) => sendWsError(ws, "list-commands", err));
      break;
    }
    case "list-files": {
      const cwd = String(msg.cwd || DEFAULT_CWD);
      Promise.resolve(cachedFiles(cwd))
        .then((files) => ws.send(JSON.stringify({ kind: "files-list", cwd, files })))
        .catch((err) => sendWsError(ws, "list-files", err));
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

for (const p of PROVIDERS) {
  refreshCatalog(p.id, process.env.CMUX_AGENT_UI_CWD ?? DEFAULT_CWD).catch((err) => {
    console.warn(`catalog warm failed for ${p.id}: ${String(err)}`);
  });
}

console.log(`cmux-agent-ui listening on http://127.0.0.1:${server.port}`);
