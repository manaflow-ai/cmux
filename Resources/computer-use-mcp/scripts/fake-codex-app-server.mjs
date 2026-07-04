#!/usr/bin/env node
// Test stub for elicitation-smoke.mjs: a fake `codex app-server` (newline
// JSON-RPC on stdio) whose computer-use tool call triggers an approval
// elicitation, then reports which action came back. Only `app-server` is
// supported; anything else exits nonzero like an unknown subcommand would.
import { createInterface } from "node:readline";
import process from "node:process";

if (process.argv[2] !== "app-server") {
  console.error(`fake-codex: unknown subcommand ${process.argv[2]}`);
  process.exit(2);
}
if (process.argv.includes("--help")) {
  // The server probes candidates with `app-server --help` before using them.
  console.log("fake codex app-server");
  process.exit(0);
}

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
let pendingToolCallId = null;
let pendingUnknownRequestToolCallId = null;
const stateCallsByApp = new Map();

const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

function toolCallParams(message) {
  const params = message.params ?? {};
  if (
    params.server !== "computer-use" ||
    typeof params.tool !== "string" ||
    hasOwn(params, "serverName") ||
    hasOwn(params, "toolName")
  ) {
    send({
      id: message.id,
      result: {
        content: [{ type: "text", text: "invalid mcpServer/tool/call params" }],
        isError: true,
      },
    });
    return null;
  }
  return params;
}

function rejectStringElementIndex(message) {
  if (!hasOwn(message.params?.arguments ?? {}, "element_index")) return false;
  if (typeof message.params?.arguments?.element_index === "number") return false;
  send({
    id: message.id,
    result: {
      content: [{ type: "text", text: "element_index must be a number" }],
      isError: true,
    },
  });
  return true;
}

createInterface({ input: process.stdin }).on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  if (message.method === "initialize") {
    send({ id: message.id, result: { userAgent: "fake-codex/0.0.1" } });
    return;
  }
  if (message.method === "thread/start") {
    send({ id: message.id, result: { thread: { id: "thread-test" } } });
    return;
  }
  if (message.method === "mcpServer/tool/call") {
    const params = toolCallParams(message);
    if (!params) return;
    if (params.tool === "get_app_state") {
      const app = params.arguments?.app;
      if (app === "UnknownRequestApp") {
        pendingUnknownRequestToolCallId = message.id;
        send({
          id: "unknown-request-1",
          method: "item/newApprovalKind",
          params: {},
        });
        return;
      }
      if (app === "SlowStateApp") {
        setTimeout(() => {
          send({
            id: message.id,
            result: {
              content: [{ type: "text", text: "slow state" }],
              isError: false,
            },
          });
        }, 5000);
        return;
      }
      const calls = (stateCallsByApp.get(app) ?? 0) + 1;
      stateCallsByApp.set(app, calls);
      if ((app === "FlakyStateApp" || app === "FlakyScreenshotApp") && calls >= 2) {
        send({
          id: message.id,
          result: {
            content: [{ type: "text", text: "state refresh failed" }],
            isError: true,
          },
        });
        return;
      }
      send({
        id: message.id,
        result: {
          content: [
            { type: "text", text: "0 button 'OK'" },
            { type: "image", data: "AA==", mimeType: "image/png" },
          ],
          isError: false,
        },
      });
      return;
    }
    if (params.tool === "click") {
      if (rejectStringElementIndex(message)) return;
      send({
        id: message.id,
        result: {
          content: [{ type: "text", text: "clicked" }],
          isError: false,
        },
      });
      return;
    }
    if (params.tool === "scroll" || params.tool === "perform_secondary_action") {
      if (rejectStringElementIndex(message)) return;
      send({
        id: message.id,
        result: {
          content: [{ type: "text", text: `${params.tool}:ok` }],
          isError: false,
        },
      });
      return;
    }
    if (params.tool === "drag") {
      send({
        id: message.id,
        result: {
          content: [{ type: "text", text: "dragged" }],
          isError: false,
        },
      });
      return;
    }
    if (params.tool === "type_text" || params.tool === "press_key") {
      send({
        id: message.id,
        result: {
          content: [{ type: "text", text: `${params.tool}:ok` }],
          isError: false,
        },
      });
      return;
    }
    pendingToolCallId = message.id;
    send({
      id: "elicit-1",
      method: "mcpServer/elicitation/request",
      params: {
        threadId: "thread-test",
        serverName: "computer-use",
        message: "Allow Codex to use TestApp?",
        mode: "form",
        requestedSchema: { type: "object", properties: {} },
      },
    });
    return;
  }
  if (message.id === "unknown-request-1" && message.method === undefined) {
    const rejected = !!message.error;
    send({
      id: pendingUnknownRequestToolCallId,
      result: {
        content: [{ type: "text", text: rejected ? "unknown-request:rejected" : "unknown-request:accepted" }],
        isError: !rejected,
      },
    });
    pendingUnknownRequestToolCallId = null;
    return;
  }
  if (message.id === "elicit-1" && message.method === undefined) {
    const action = message.result?.action ?? "missing";
    send({
      id: pendingToolCallId,
      result: {
        content: [{ type: "text", text: `elicitation:${action}` }],
        isError: action !== "accept",
      },
    });
  }
});
