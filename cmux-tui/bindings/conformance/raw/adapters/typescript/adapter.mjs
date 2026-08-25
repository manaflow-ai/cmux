#!/usr/bin/env node
// Protocol-10 conformance adapter for the public TypeScript/Node SDK.

import {
  CmuxAuthorityError,
  CmuxClient,
  CmuxCommandError,
  CmuxProtocolError,
  CmuxTimeoutError,
  COMMAND_METADATA,
  EVENT_METADATA,
  UnixSocketTransport,
} from "../../../../typescript/dist/src/raw/index.js";
import { Buffer } from "node:buffer";

const UINT64_KEYS = new Set([
  "client",
  "index",
  "offset",
  "pane",
  "pane_revision",
  "projection_revision",
  "request",
  "screen",
  "seq",
  "surface",
  "terminal_revision",
  "timeout_ms",
  "workspace",
  "workspace_revision",
]);

function normalize(value, key = undefined) {
  if (typeof value === "bigint") return value.toString();
  if (value instanceof Uint8Array) return Buffer.from(value).toString("base64");
  if (Array.isArray(value)) return value.map((item) => normalize(item));
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, item]) => item !== undefined)
        .map(([itemKey, item]) => [itemKey, normalize(item, itemKey)]),
    );
  }
  if (
    typeof value === "number"
    && Number.isInteger(value)
    && (UINT64_KEYS.has(key) || key?.endsWith("_revision"))
  ) {
    return String(value);
  }
  return value;
}

function classify(error) {
  const text = String(error?.message ?? error).toLowerCase();
  if (error instanceof CmuxTimeoutError || text.includes("timed out") || text.includes("did not produce")) {
    return "timeout";
  }
  if (text.includes("exceed") || text.includes("limit") || text.includes("buffer overflow")) {
    return "limit";
  }
  if (error instanceof CmuxCommandError) return "command";
  if (
    error instanceof CmuxProtocolError
    || text.includes("utf-8")
    || text.includes("json")
    || text.includes("decode")
  ) {
    return "decode";
  }
  return "transport";
}

function metadata() {
  return {
    commands: Object.entries(COMMAND_METADATA).map(([name, item]) => ({
      name,
      authority: item.authority,
      stream: item.stream?.kind ?? null,
    })),
    events: Object.entries(EVENT_METADATA).map(([name, item]) => ({
      name,
      streams: [...item.streams],
    })),
  };
}

function makeClient(request, enableProviderAuthority = false) {
  const maxInboundMessageBytes = Number(request.max_frame_bytes ?? 16 * 1024 * 1024);
  const transportOptions = { maxInboundMessageBytes };
  const makeTransport = () => new UnixSocketTransport(request.socket_path, transportOptions);
  const authorities = request.authority === "local-admin"
    ? ["frontend", "local-admin"]
    : undefined;
  return new CmuxClient({
    socketPath: request.socket_path,
    timeoutMs: Number(request.timeout_ms ?? 1000),
    maxBufferedEvents: Number(request.max_buffered_events ?? 256),
    authorities,
    enableProviderAuthority,
    transport: makeTransport(),
    streamTransportFactory: makeTransport,
  });
}

async function identify(request) {
  const client = makeClient(request);
  try {
    const value = await client.identify();
    return {
      app: value.app,
      protocol: value.protocol,
      workspace_revision: value.workspace_revision.toString(),
      terminal_revision: value.terminal_revision.toString(),
    };
  } finally {
    await client.close();
  }
}

async function nullableLiteral(request) {
  const client = makeClient(request);
  try {
    const value = await client.createTerminal({ key: "workspace-key" });
    return { lifecycle: value.lifecycle };
  } finally {
    await client.close();
  }
}

async function optionalNonNullResponse(request) {
  const client = makeClient(request);
  try {
    const value = await client.identify();
    return { present: value.capabilities !== undefined };
  } finally {
    await client.close();
  }
}

async function optionalNullableRequest(request) {
  const client = makeClient(request);
  const presence = String(request.presence);
  try {
    switch (presence) {
      case "omitted":
        await client.request("set-client-info", {});
        break;
      case "null":
        await client.request("set-client-info", { name: null });
        break;
      case "value":
        await client.request("set-client-info", { name: "conformance-client" });
        break;
      default:
        throw new Error(`unknown presence ${presence}`);
    }
    return { presence };
  } finally {
    await client.close();
  }
}

async function openStream(client, request) {
  switch (request.stream) {
    case "subscribe-coarse":
      return client.subscribe();
    case "subscribe-deltas":
      return client.subscribe({ treeEvents: "deltas" });
    case "attach-byte":
      return client.attachSurface(BigInt(request.surface ?? "7"), { mode: "bytes" });
    case "attach-render":
      return client.attachSurface(BigInt(request.surface ?? "7"), { mode: "render" });
    case "attach-browser":
      return client.attachSurface(BigInt(request.surface ?? "7"), { mode: "bytes" });
    default:
      throw new Error(`unknown stream ${String(request.stream)}`);
  }
}

function normalizeEvent(event) {
  if (!(event.event in EVENT_METADATA)) {
    return { event: event.event, unknown: true, raw: normalize(event) };
  }
  return normalize(event);
}

async function stream(request) {
  const client = makeClient(request);
  const events = [];
  let terminal = false;
  let opened;
  try {
    opened = await openStream(client, request);
    for (let index = 0; index < Number(request.events ?? 1); index += 1) {
      try {
        const event = await opened.next(Number(request.timeout_ms ?? 1000));
        events.push(normalizeEvent(event));
        if (event.event === "overflow" || event.event === "detached") terminal = true;
      } catch (error) {
        if (terminal || String(error?.message ?? error).includes("closed")) {
          terminal = true;
          break;
        }
        throw error;
      }
    }
    return { events, terminal };
  } finally {
    opened?.close();
    await client.close();
  }
}

async function requiredNullableEvent(request) {
  const client = makeClient(request);
  let opened;
  try {
    opened = await client.subscribe();
    const event = await opened.next(Number(request.timeout_ms ?? 1000));
    if (event.event !== "client-changed") {
      throw new CmuxProtocolError(`expected client-changed event, got ${event.event}`);
    }
    return { name: event.name };
  } finally {
    opened?.close();
    await client.close();
  }
}

async function optionalNonNullEvent(request) {
  const client = makeClient(request);
  let opened;
  try {
    opened = await openStream(client, request);
    const event = await opened.next(Number(request.timeout_ms ?? 1000));
    if (event.event !== "output") {
      throw new CmuxProtocolError(`expected output event, got ${event.event}`);
    }
    return { present: event.colors !== undefined };
  } finally {
    opened?.close();
    await client.close();
  }
}

async function closePendingStream(request) {
  const client = makeClient(request);
  let opened;
  try {
    opened = await openStream(client, request);
    const pending = opened.next(Number(request.deadline_ms ?? 1000) * 4)
      .then(() => true, () => true);
    await new Promise((resolve) => setTimeout(resolve, Number(request.close_after_ms ?? 50)));
    opened.close();
    const unblocked = await Promise.race([
      pending,
      new Promise((resolve) => setTimeout(() => resolve(false), Number(request.deadline_ms ?? 1000))),
    ]);
    return { unblocked };
  } finally {
    opened?.close();
    await client.close();
  }
}

async function authority(request) {
  const client = makeClient(request, request.authority === "provider-authority");
  let command;
  try {
    switch (request.authority) {
      case "control":
        await client.ping();
        command = "ping";
        break;
      case "frontend":
        await client.browserBack({ surface: 7n });
        command = "browser-back";
        break;
      case "local-admin":
        await client.pairingResponse({ request: 1n, approve: false });
        command = "pairing-response";
        break;
      case "provider-authority":
        await client.markWorkspacesProviderManaged({ authority: "conformance-authority" });
        command = "mark-workspaces-provider-managed";
        break;
      default:
        throw new Error(`unknown authority ${String(request.authority)}`);
    }
  } finally {
    await client.close();
  }
  return { command };
}

async function authorityDenied(request) {
  const client = makeClient(request);
  try {
    await client.markWorkspacesProviderManaged({ authority: "conformance-authority" });
  } catch (error) {
    if (error instanceof CmuxAuthorityError) return { denied: true };
    throw error;
  } finally {
    await client.close();
  }
  throw new Error("default client allowed provider-authority command");
}

function findSurface(tree, surface) {
  for (const workspace of tree.workspaces) {
    for (const screen of workspace.screens) {
      for (const pane of screen.panes) {
        if (!("tabs" in pane)) continue;
        const tab = pane.tabs.find((item) => item.surface === surface);
        if (tab) return { workspace, screen, pane, tab };
      }
    }
  }
  return undefined;
}

async function realFlow(request) {
  const marker = String(request.marker ?? "cmux-sdk-conformance-marker");
  const workspaceName = String(request.workspace_name ?? "sdk-conformance-workspace");
  const renamedName = String(request.renamed_name ?? "sdk-conformance-renamed");
  const client = makeClient(request);
  let opened;
  let workspace;
  let closed = false;
  try {
    const identity = await client.identify();
    opened = await client.subscribe({ treeEvents: "deltas" });
    const created = await client.newWorkspace({ name: workspaceName, cols: 80, rows: 24 });
    const surface = created.surface;
    await client.send(surface, { text: `printf '${marker}\\n'\r` });
    const waited = await client.waitFor(surface, marker, 5_000);
    const screenText = await client.readScreen(surface);
    const context = findSurface(await client.listWorkspaces(), surface);
    if (!context) throw new Error(`created surface ${surface} is absent from the tree`);
    workspace = context.workspace.id;
    const terminalCreated = context.tab.kind === "pty" && !context.tab.dead;
    await client.renameWorkspace(workspace, renamedName);
    const renamedTree = await client.listWorkspaces();
    const renamed = renamedTree.workspaces.some(
      (item) => item.id === workspace && item.name === renamedName,
    );
    await client.closeWorkspace(workspace);
    closed = true;
    const remaining = await client.listWorkspaces();
    const disappeared = remaining.workspaces.every((item) => item.id !== workspace);

    const requiredEvents = ["workspace-added", "workspace-renamed", "workspace-closed"];
    const observed = [];
    for (let index = 0; index < 64; index += 1) {
      if (requiredEvents.every((name) => observed.includes(name))) break;
      observed.push((await opened.next(Number(request.timeout_ms ?? 5_000))).event);
    }
    const positions = requiredEvents.map((name) => observed.indexOf(name));
    const streamOrdered = positions.every(
      (position, index) => position >= 0 && (index === 0 || position > positions[index - 1]),
    );
    return {
      identified: identity.protocol === 12,
      workspace_created: workspace > 0n,
      terminal_created: terminalCreated,
      marker_sent: true,
      wait_matched: waited.matched === true,
      read_contains_marker: screenText.text.includes(marker),
      stream_ordered: streamOrdered,
      renamed,
      closed,
      disappeared,
      observed_events: observed,
    };
  } finally {
    if (workspace !== undefined && !closed) {
      try {
        await client.closeWorkspace(workspace);
      } catch {
        // Preserve the primary conformance failure.
      }
    }
    opened?.close();
    await client.close();
  }
}

async function dispatch(request) {
  switch (request.op) {
    case "metadata":
      return metadata();
    case "identify":
      return identify(request);
    case "nullable-literal":
      return nullableLiteral(request);
    case "optional-non-null-response":
      return optionalNonNullResponse(request);
    case "optional-nullable-request":
      return optionalNullableRequest(request);
    case "stream":
      return stream(request);
    case "required-nullable-event":
      return requiredNullableEvent(request);
    case "optional-non-null-event":
      return optionalNonNullEvent(request);
    case "close-pending-stream":
      return closePendingStream(request);
    case "authority":
      return authority(request);
    case "authority-denied":
      return authorityDenied(request);
    case "real-flow":
      return realFlow(request);
    default:
      throw new Error(`unknown adapter operation ${String(request.op)}`);
  }
}

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const request = JSON.parse(Buffer.concat(chunks).toString("utf8").trim());
const response = { contract_version: 1, id: request.id };
try {
  response.value = await dispatch(request);
  response.ok = true;
} catch (error) {
  response.ok = false;
  response.error = { kind: classify(error), message: String(error?.message ?? error) };
}
process.stdout.write(`${JSON.stringify(response)}\n`);
