import { createConnection } from "node:net";

const MAX_FRAME_BYTES = 16 * 1024 * 1024;
const MAX_PENDING_EVENTS = 256;
const ATTACH_TIMEOUT_MS = 5_000;
const TURN_ENDS = new Set(["stopping", "turn_end", "turn_error", "turn_result"]);

/** Attach before spawning: a script belongs to this turn, never the following one.
 * The owner-only acpmux socket permits this read without a person credential.
 * Closing the socket, a lost event, or an ended owner all fail closed.
 */
export async function watchOwnerTurn(env, onEnd, signal) {
  const sessionId = env.ACPMUX_SESSION_ID;
  const socketPath = env.ACPMUX_SOCKET;
  if (!sessionId && !socketPath) return () => {};
  if (!sessionId || !socketPath) throw new Error("code mode: incomplete acpmux owner identity");
  if (signal?.aborted) throw new Error("code mode: owner attachment aborted");

  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    let pending = Buffer.alloc(0);
    let turnId;
    let attached = false;
    let closed = false;
    const earlyEvents = [];
    const cleanup = () => {
      if (closed) return;
      closed = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      socket.destroy();
    };
    const end = (reason) => {
      if (closed) return;
      cleanup();
      if (!attached) reject(new Error(`code mode: ${reason}`));
      onEnd(reason);
    };
    const abort = () => end("owner attachment aborted");
    const timer = setTimeout(() => end("owner attachment timed out"), ATTACH_TIMEOUT_MS);
    signal?.addEventListener("abort", abort, { once: true });

    const event = (record, historical = false) => {
      if (record?.sessionId !== sessionId) return;
      if (TURN_ENDS.has(record.kind) && record.msg?.turnId === turnId) {
        end(`owner turn ${record.kind}`);
      } else if (!historical && (record.kind === "purged"
        || (record.kind === "status" && ["closed", "stopping"].includes(record.msg?.status)))) {
        end("owner session stopped");
      }
    };

    const receive = (message) => {
      if (message.method === "_acpmux/lagged") return end("owner lifecycle events lost");
      if (message.method === "_acpmux/event") {
        if (attached) event(message.params);
        else if (earlyEvents.length < MAX_PENDING_EVENTS) earlyEvents.push(message.params);
        else end("owner lifecycle event backlog exceeded");
        return;
      }
      if (message.id !== "code-mode-owner") return;
      if (attached) return end("duplicate owner attachment response");
      const owner = message.result?.session;
      turnId = owner?.turn?.turnId;
      if (message.error || owner?.sessionId !== sessionId || typeof turnId !== "string"
        || !turnId || ["closed", "stopping"].includes(owner.state)
        || ["closed", "stopping"].includes(owner.status)) {
        return end("owner has no active turn");
      }
      // Subscribe precedes the snapshot on the daemon. A turn may end between
      // that snapshot and this reply; neither buffered nor replayed ends are lost.
      for (const record of message.result.events ?? []) event(record, true);
      for (const record of earlyEvents) event(record);
      earlyEvents.length = 0;
      if (closed) return;
      attached = true;
      clearTimeout(timer);
      resolve(cleanup);
    };

    socket.on("connect", () => {
      if (closed) return;
      socket.write(`${JSON.stringify({
        jsonrpc: "2.0", id: "code-mode-owner", method: "_acpmux/attach",
        params: {
          sessionId, visible: false, eventStream: true, limit: 1,
          kinds: [...TURN_ENDS, "status", "purged"],
        },
      })}\n`);
    });
    socket.on("data", (chunk) => {
      if (closed) return;
      pending = Buffer.concat([pending, chunk]);
      while (!closed) {
        const newline = pending.indexOf(10);
        if (newline < 0) {
          if (pending.length > MAX_FRAME_BYTES) end("owner lifecycle frame too large");
          return;
        }
        if (newline > MAX_FRAME_BYTES) return end("owner lifecycle frame too large");
        const line = pending.subarray(0, newline);
        pending = pending.subarray(newline + 1);
        try {
          const message = JSON.parse(line.toString("utf8"));
          if (!message || message.jsonrpc !== "2.0") throw new Error("invalid JSON-RPC");
          receive(message);
        } catch {
          end("invalid owner lifecycle frame");
        }
      }
    });
    socket.on("error", () => end("owner lifecycle connection failed"));
    socket.on("close", () => end("owner lifecycle connection closed"));
  });
}
