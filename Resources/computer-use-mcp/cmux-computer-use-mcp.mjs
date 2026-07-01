#!/usr/bin/env node
// cmux computer use — agent-agnostic MCP server.
//
// Exposes the standard Codex Computer Use engine to ANY MCP agent (Claude,
// Codex, …): the same AX-tree-grounded screenshot perception and element-index
// click/type/scroll action loop Codex Computer Use itself uses, driving the
// local Mac. No custom engine: this server spawns `codex app-server` (stdio)
// from the user's standard Codex install and proxies tool calls to its bundled
// `computer-use` MCP server (initialize -> thread/start -> mcpServer/tool/call).
//
// Requirements (exactly what Codex Computer Use requires):
//   - a Codex install that bundles the computer-use plugin: `codex` on PATH
//     (@openai/codex npm package) or /Applications/Codex.app
//   - a logged-in Codex (~/.codex/auth.json)
//   - macOS permissions granted to the Codex Computer Use helper app
//     (Codex prompts for Accessibility/Screen Recording on first use)
//
// This file is dependency-free (plain node) so cmux can ship it inside the app
// bundle and attach it to agent launches without an install step.
//
// Config (env):
//   CMUX_CU_CODEX       path to the codex binary
//                       (default: `codex` on PATH, then Codex.app's bundled codex)
//   CMUX_CU_TIMEOUT_MS  per-command timeout (default 180000)
//   CMUX_CU_MAX_TREE    max AX-tree chars returned by computer_state (default 60000)

import { spawn, execFile } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access, readFile, rm } from "node:fs/promises";
import { createInterface } from "node:readline";
import { homedir, tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { promisify } from "node:util";
import process from "node:process";

const execFileP = promisify(execFile);

const TIMEOUT_MS = Number(process.env.CMUX_CU_TIMEOUT_MS || 180000);
const MAX_TREE = Number(process.env.CMUX_CU_MAX_TREE || 60000);
const CODEX_APP_BINARY = "/Applications/Codex.app/Contents/Resources/codex";

async function isExecutable(path) {
  try {
    await access(path, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

async function resolveCodexBinary() {
  const override = (process.env.CMUX_CU_CODEX || "").trim();
  if (override) {
    if (await isExecutable(override)) return override;
    throw new Error(`CMUX_CU_CODEX is set but not executable: ${override}`);
  }
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, "codex");
    if (await isExecutable(candidate)) return candidate;
  }
  if (await isExecutable(CODEX_APP_BINARY)) return CODEX_APP_BINARY;
  throw new Error(
    "codex binary not found. Install the Codex CLI (npm i -g @openai/codex) or " +
      "Codex.app, or point CMUX_CU_CODEX at a codex binary."
  );
}

// ---- codex app-server session (one persistent child + one ephemeral thread) ----
//
// The app-server speaks newline-delimited JSON-RPC over stdio (`--listen
// stdio://` is its default transport). The computer-use MCP server keeps its
// element-index table per thread, so we hold one thread open for the whole MCP
// session: computer_state builds the indices and the action tools reuse them.

class AppServerSession {
  constructor(codexBinary) {
    this.codexBinary = codexBinary;
    this.child = null;
    this.threadId = null;
    this.nextId = 1;
    this.pending = new Map();
    this.primedApps = new Set();
    this.startPromise = null;
    this.exitError = null;
  }

  get alive() {
    return this.child !== null && this.exitError === null && this.threadId !== null;
  }

  async ensureStarted() {
    if (this.alive) return;
    if (!this.startPromise) {
      this.startPromise = this.start().finally(() => {
        this.startPromise = null;
      });
    }
    await this.startPromise;
  }

  async start() {
    this.dispose();
    this.exitError = null;
    const child = spawn(this.codexBinary, ["app-server"], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;
    // Writes can race the child dying; the exit handler already rejects all
    // pending requests, so a stdin error must not crash the server.
    child.stdin.on("error", () => {});
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      process.stderr.write(`[codex app-server] ${chunk}`);
    });
    child.on("error", (error) => this.onExit(`failed to spawn codex app-server: ${error.message}`));
    child.on("exit", (code, signal) => {
      this.onExit(
        `codex app-server exited before returning a response (code ${code ?? "?"}, signal ${signal ?? "none"})`
      );
    });
    createInterface({ input: child.stdout }).on("line", (line) => this.onLine(line));

    await this.request("initialize", {
      clientInfo: { name: "cmux-computer-use", version: "0.2.0" },
      capabilities: { experimentalApi: true },
    });
    this.notify("initialized");
    const started = await this.request("thread/start", {
      cwd: homedir(),
      ephemeral: true,
      serviceName: "cmux-computer-use",
    });
    const threadId = started?.thread?.id;
    if (!threadId) throw new Error("codex app-server thread/start returned no thread id");
    this.threadId = threadId;
  }

  onExit(message) {
    if (this.exitError === null) this.exitError = message;
    this.threadId = null;
    this.primedApps.clear();
    const pending = [...this.pending.values()];
    this.pending.clear();
    for (const entry of pending) {
      clearTimeout(entry.timer);
      entry.reject(new Error(this.exitError));
    }
  }

  onLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    // Server -> client request: answer like a non-interactive Codex client.
    // Computer-use control elicitations are accepted (that IS the tool's
    // purpose); command/file approvals are declined — this server only ever
    // drives the computer-use MCP, never shell or patch tools.
    if (message.method && message.id != null) {
      let result = {};
      switch (message.method) {
        case "mcpServer/elicitation/request":
          result = { action: "accept", content: {} };
          break;
        case "item/permissions/requestApproval":
          result = { permissions: {}, scope: "turn" };
          break;
        case "item/tool/requestUserInput":
          result = { answers: {} };
          break;
        case "item/commandExecution/requestApproval":
        case "item/fileChange/requestApproval":
        case "applyPatchApproval":
        case "execCommandApproval":
          result = { decision: "decline", reason: "cmux computer use does not grant command/file approvals" };
          break;
        default:
          break;
      }
      this.write({ id: message.id, result });
      return;
    }
    if (message.id == null || !this.pending.has(message.id)) return;
    const entry = this.pending.get(message.id);
    this.pending.delete(message.id);
    clearTimeout(entry.timer);
    if (message.error) {
      const code = message.error.code != null ? ` (code ${message.error.code})` : "";
      entry.reject(new Error(`${entry.method} failed: ${message.error.message}${code}`));
    } else {
      entry.resolve(message.result);
    }
  }

  write(message) {
    if (!this.child || this.exitError !== null) throw new Error(this.exitError || "codex app-server is not running");
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  notify(method, params) {
    const message = { method };
    if (params !== undefined) message.params = params;
    this.write(message);
  }

  request(method, params) {
    return new Promise((resolve, reject) => {
      if (this.exitError !== null) {
        reject(new Error(this.exitError));
        return;
      }
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out after ${TIMEOUT_MS}ms`));
      }, TIMEOUT_MS);
      this.pending.set(id, { resolve, reject, timer, method });
      try {
        const message = { id, method };
        if (params !== undefined) message.params = params;
        this.write(message);
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  async callTool(tool, args) {
    await this.ensureStarted();
    return this.request("mcpServer/tool/call", {
      threadId: this.threadId,
      server: "computer-use",
      tool,
      arguments: args,
    });
  }

  dispose() {
    const child = this.child;
    this.child = null;
    this.threadId = null;
    this.primedApps.clear();
    if (child) {
      child.removeAllListeners("exit");
      child.kill();
    }
  }
}

let sessionPromise = null;

async function session() {
  if (!sessionPromise) {
    sessionPromise = (async () => new AppServerSession(await resolveCodexBinary()))();
    sessionPromise.catch(() => {
      sessionPromise = null;
    });
  }
  return sessionPromise;
}

function isColdStartError(error) {
  return /exited before returning a response|-10005/.test(String(error?.message ?? error));
}

// The first Computer Use call after the app-server (re)starts can fail while
// the bundled computer-use service warms up. Retry once — but only for
// read-only perception commands, never for input actions.
async function callReadOnlyTool(tool, args) {
  const s = await session();
  try {
    return await s.callTool(tool, args);
  } catch (error) {
    if (!isColdStartError(error)) throw error;
    await new Promise((resolve) => setTimeout(resolve, 2000));
    return s.callTool(tool, args);
  }
}

// Input actions require the app to be bound in the current app-server thread.
// A `get_app_state` in the same thread does that binding (and builds the
// element-index table), so prime once per app — matching the engine's own
// state -> act loop. Element indices still come from the agent's latest
// computer_state; tools tell agents to re-capture before element actions.
async function callInputTool(tool, args) {
  const s = await session();
  const app = typeof args.app === "string" ? args.app.trim() : "";
  if (app && !s.alive) s.primedApps.clear();
  if (app) {
    await s.ensureStarted();
    if (!s.primedApps.has(app)) {
      const primed = await s.callTool("get_app_state", { app });
      if (primed?.isError) {
        return primed;
      }
      s.primedApps.add(app);
    }
  }
  return s.callTool(tool, args);
}

const text = (value) => ({ type: "text", text: String(value) });

function firstText(result) {
  for (const item of result?.content ?? []) {
    if (item?.type === "text" && typeof item.text === "string") return item.text;
  }
  return "";
}

function firstImage(result) {
  for (const item of result?.content ?? []) {
    if (item?.type === "image" && item.data && item.mimeType) {
      return { type: "image", data: item.data, mimeType: item.mimeType };
    }
  }
  return null;
}

function truncateTree(tree) {
  if (tree.length <= MAX_TREE) return tree;
  return `${tree.slice(0, MAX_TREE)}\n…[truncated AX tree]`;
}

function ok(content) {
  return { content, isError: false };
}

function err(message, stdout = "") {
  const parts = [];
  if (stdout) parts.push(text(stdout));
  parts.push(text(`ERROR: ${message}`));
  return { content: parts, isError: true };
}

function passthrough(result, fallback) {
  if (result?.isError) return { content: result.content ?? [text("(error)")], isError: true };
  const body = firstText(result);
  return ok([text(body || fallback)]);
}

// Perception result -> MCP content: AX tree as text + screenshot as image, so
// a vision agent sees exactly what Codex Computer Use sees.
async function perceive(app) {
  const result = await callReadOnlyTool("get_app_state", { app });
  if (result?.isError) return { content: result.content ?? [text("(error)")], isError: true };
  const s = await session();
  if (s.alive) s.primedApps.add(app);
  const tree = truncateTree(firstText(result));
  const image = firstImage(result);
  const content = [
    text(
      tree
        ? `Accessibility tree (element indices are valid only for THIS snapshot):\n\n${tree}`
        : "(captured)"
    ),
  ];
  if (image) content.push(image);
  else content.push(text("(no screenshot returned by the computer-use engine)"));
  return ok(content);
}

async function desktopScreenshot(display) {
  const path = join(
    tmpdir(),
    `cmux-cu-screenshot-${process.pid}-${Date.now()}-${Math.floor(Math.random() * 1e6)}.png`
  );
  const args = ["-x"];
  if (display != null) args.push("-D", String(display));
  args.push(path);
  try {
    await execFileP("/usr/sbin/screencapture", args, { timeout: TIMEOUT_MS });
    const data = await readFile(path);
    return ok([{ type: "image", data: data.toString("base64"), mimeType: "image/png" }]);
  } catch (error) {
    return err(
      `screencapture failed: ${error?.message ?? error}. Full-desktop capture needs macOS ` +
        "Screen Recording permission for the terminal app; per-app capture via `app` does not."
    );
  } finally {
    rm(path, { force: true }).catch(() => {});
  }
}

// CGWindowList via `swift -` (the JXA ObjC bridge crashes on this call on
// recent macOS). Window titles require Screen Recording permission; without
// it they are simply omitted (the rest of the metadata still lists correctly).
const WINDOW_LIST_SWIFT = `
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    print("[]")
    exit(0)
}
var windows: [[String: Any]] = []
for entry in list {
    var window: [String: Any] = [:]
    window["id"] = entry[kCGWindowNumber as String] ?? 0
    window["app"] = entry[kCGWindowOwnerName as String] ?? ""
    window["title"] = entry[kCGWindowName as String] ?? ""
    window["pid"] = entry[kCGWindowOwnerPID as String] ?? 0
    window["layer"] = entry[kCGWindowLayer as String] ?? 0
    window["bounds"] = entry[kCGWindowBounds as String] ?? [String: Any]()
    windows.append(window)
}
let data = try JSONSerialization.data(withJSONObject: windows, options: [.sortedKeys])
print(String(data: data, encoding: .utf8) ?? "[]")
`;

function runWithStdin(command, args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
    child.stdin.on("error", () => {}); // spawn failure surfaces via the error/close handlers
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`${command} timed out after ${TIMEOUT_MS}ms`));
    }, TIMEOUT_MS);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(stdout);
      else reject(new Error(stderr.trim() || `${command} exited with code ${code}`));
    });
    child.stdin.end(input);
  });
}

async function listWindows(match) {
  let stdout;
  try {
    stdout = await runWithStdin("/usr/bin/swift", ["-"], WINDOW_LIST_SWIFT);
  } catch (error) {
    throw new Error(
      `window listing needs the macOS Swift toolchain (xcode-select --install): ${error?.message ?? error}`
    );
  }
  let windows = JSON.parse(stdout);
  windows = windows.filter((w) => w.layer === 0);
  if (match) {
    const needle = match.toLowerCase();
    windows = windows.filter(
      (w) => String(w.app).toLowerCase().includes(needle) || String(w.title).toLowerCase().includes(needle)
    );
  }
  return windows;
}

const TOOLS = [
  {
    name: "computer_target",
    description:
      "Report which machine cmux computer use is driving (the local Mac) and the Codex engine in use. Call once at the start.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async () => {
      const s = await session();
      return ok([text(`target=local Mac engine=codex app-server (computer-use MCP) codex=${s.codexBinary}`)]);
    },
  },
  {
    name: "computer_apps",
    description: "List the controllable apps on the target machine.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    run: async () => passthrough(await callReadOnlyTool("list_apps", {}), "(no apps)"),
  },
  {
    name: "computer_open",
    description: "Launch or focus an app by name on the target machine.",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string", description: "App name, e.g. Safari" } },
      required: ["app"],
      additionalProperties: false,
    },
    run: async ({ app }) => {
      try {
        const { stdout } = await execFileP("/usr/bin/open", ["-a", app], { timeout: TIMEOUT_MS });
        return ok([text(stdout?.trim() || `opened ${app}`)]);
      } catch (error) {
        return err(error?.stderr?.trim() || error?.message || String(error));
      }
    },
  },
  {
    name: "computer_state",
    description:
      "PRIMARY perception. Capture an app's accessibility tree + a screenshot. Returns element indices used by computer_click/scroll/action. Re-capture before each action; indices are snapshot-specific.",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string", description: "App name to inspect" } },
      required: ["app"],
      additionalProperties: false,
    },
    run: async ({ app }) => perceive(app),
  },
  {
    name: "computer_screenshot",
    description:
      "Capture a screenshot. Pass `app` for one app's window, or omit `app` (optionally `display`) for the full desktop.",
    inputSchema: {
      type: "object",
      properties: {
        app: { type: "string", description: "App name; omit for full desktop" },
        display: { type: "number", description: "Display number for full-desktop capture" },
      },
      additionalProperties: false,
    },
    run: async ({ app, display }) => {
      if (!app) return desktopScreenshot(display);
      const result = await callReadOnlyTool("get_app_state", { app });
      if (result?.isError) return { content: result.content ?? [text("(error)")], isError: true };
      const s = await session();
      if (s.alive) s.primedApps.add(app);
      const image = firstImage(result);
      return ok(image ? [image] : [text("(captured, no image)")]);
    },
  },
  {
    name: "computer_click",
    description:
      "Click in an app. Prefer `element` (index from the latest computer_state). Use x/y screen points only when no element fits.",
    inputSchema: {
      type: "object",
      properties: {
        app: { type: "string" },
        element: { type: "number", description: "Element index from latest computer_state" },
        x: { type: "number" },
        y: { type: "number" },
      },
      required: ["app"],
      additionalProperties: false,
    },
    run: async ({ app, element, x, y }) => {
      const args = { app, mouse_button: "left", click_count: 1 };
      if (element != null) args.element_index = String(element);
      else if (x != null && y != null) {
        args.x = x;
        args.y = y;
      } else return err("provide either `element` or both `x` and `y`");
      return passthrough(await callInputTool("click", args), "clicked");
    },
  },
  {
    name: "computer_type",
    description: "Type text into an app (the focused field).",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string" }, text: { type: "string" } },
      required: ["app", "text"],
      additionalProperties: false,
    },
    run: async ({ app, text: value }) =>
      passthrough(await callInputTool("type_text", { app, text: value }), "typed"),
  },
  {
    name: "computer_key",
    description: "Press a key / chord in an app, e.g. Return, Escape, cmd+l, cmd+t.",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string" }, key: { type: "string" } },
      required: ["app", "key"],
      additionalProperties: false,
    },
    run: async ({ app, key }) => passthrough(await callInputTool("press_key", { app, key }), "key sent"),
  },
  {
    name: "computer_scroll",
    description: "Scroll an element in a direction (up/down/left/right), optionally by N pages.",
    inputSchema: {
      type: "object",
      properties: {
        app: { type: "string" },
        element: { type: "number" },
        direction: { type: "string", enum: ["up", "down", "left", "right"] },
        pages: { type: "number" },
      },
      required: ["app", "element", "direction"],
      additionalProperties: false,
    },
    run: async ({ app, element, direction, pages }) =>
      passthrough(
        await callInputTool("scroll", {
          app,
          element_index: String(element),
          direction,
          pages: pages ?? 1,
        }),
        "scrolled"
      ),
  },
  {
    name: "computer_drag",
    description: "Drag within an app from one screen point to another.",
    inputSchema: {
      type: "object",
      properties: {
        app: { type: "string" },
        fromX: { type: "number" },
        fromY: { type: "number" },
        toX: { type: "number" },
        toY: { type: "number" },
      },
      required: ["app", "fromX", "fromY", "toX", "toY"],
      additionalProperties: false,
    },
    run: async ({ app, fromX, fromY, toX, toY }) =>
      passthrough(
        await callInputTool("drag", { app, from_x: fromX, from_y: fromY, to_x: toX, to_y: toY }),
        "dragged"
      ),
  },
  {
    name: "computer_action",
    description: "Invoke a named accessibility action on an element (from the latest computer_state).",
    inputSchema: {
      type: "object",
      properties: {
        app: { type: "string" },
        element: { type: "number" },
        action: { type: "string" },
      },
      required: ["app", "element", "action"],
      additionalProperties: false,
    },
    run: async ({ app, element, action }) =>
      passthrough(
        await callInputTool("perform_secondary_action", {
          app,
          element_index: String(element),
          action,
        }),
        "action sent"
      ),
  },
  {
    name: "computer_windows",
    description: "List windows on the target machine (JSON), optionally filtered by a match string.",
    inputSchema: {
      type: "object",
      properties: { match: { type: "string" } },
      additionalProperties: false,
    },
    run: async ({ match }) => {
      try {
        return ok([text(JSON.stringify(await listWindows(match), null, 2))]);
      } catch (error) {
        return err(error?.message ?? String(error));
      }
    },
  },
];

// ---- MCP stdio server (newline-delimited JSON-RPC 2.0) ----

const MCP_PROTOCOL_VERSION = "2025-06-18";
const SUPPORTED_MCP_PROTOCOL_VERSIONS = new Set(["2024-11-05", "2025-03-26", "2025-06-18"]);

function mcpReply(id, result) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function mcpError(id, code, message) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`);
}

async function handleRequest(message) {
  const { id, method, params } = message;
  switch (method) {
    case "initialize":
      mcpReply(id, {
        protocolVersion: SUPPORTED_MCP_PROTOCOL_VERSIONS.has(params?.protocolVersion)
          ? params.protocolVersion
          : MCP_PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: "cmux-computer-use", version: "0.2.0" },
      });
      return;
    case "ping":
      mcpReply(id, {});
      return;
    case "tools/list":
      mcpReply(id, {
        tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
      });
      return;
    case "tools/call": {
      const tool = TOOLS.find((t) => t.name === params?.name);
      if (!tool) {
        mcpReply(id, err(`unknown tool: ${params?.name}`));
        return;
      }
      try {
        mcpReply(id, await tool.run(params?.arguments ?? {}));
      } catch (error) {
        mcpReply(id, err(error?.message ?? String(error)));
      }
      return;
    }
    default:
      mcpError(id, -32601, `method not found: ${method}`);
  }
}

async function shutdown() {
  try {
    const s = await Promise.race([sessionPromise, Promise.resolve(null)]);
    s?.dispose();
  } catch {
    // best effort
  }
  process.exit(0);
}

const stdinLines = createInterface({ input: process.stdin });
stdinLines.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let message;
  try {
    message = JSON.parse(trimmed);
  } catch {
    return;
  }
  if (message.id === undefined || message.method === undefined) return; // notification/response
  handleRequest(message).catch((error) => {
    mcpError(message.id, -32603, error?.message ?? String(error));
  });
});
stdinLines.on("close", () => {
  void shutdown();
});
process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());

console.error("[cmux-computer-use] ready — target=local Mac engine=codex app-server");
