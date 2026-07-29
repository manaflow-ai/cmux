#!/usr/bin/env node
// Public resource conformance adapter for the TypeScript Node entrypoint.

import {
  ExternalMachineSpecifier,
  RendererGrant,
  ResourceError,
  StreamError,
  decimalString,
  selectCurrent,
  sessionId,
  terminalId,
  workspaceId,
} from "../../../typescript/dist/src/index.js";
import { NodeClient } from "../../../typescript/dist/src/node.js";

function errorValue(error) {
  return {
    code: error.code,
    message: error.message,
    details: error.details,
    retryable: error.retryable,
  };
}

function getSession(client, constants) {
  return client.session(sessionId(constants.session));
}

function getWorkspace(client, constants) {
  return getSession(client, constants).workspace(workspaceId(constants.workspace));
}

function mutationValue(result) {
  const snapshot = result.value.snapshot;
  if (!snapshot) throw new Error("mutation result handle omitted its snapshot");
  return {
    workspace_id: snapshot.id,
    name: snapshot.name,
    generation: result.generation,
    revision: result.revision,
    replayed: result.replayed,
  };
}

function unknownValue(item) {
  const value = item.value;
  if (
    typeof value?.kind === "string"
    && value.kind !== "snapshot"
    && value.kind !== "delta"
    && value.raw
    && typeof value.raw === "object"
  ) {
    return { kind: value.kind, raw: value.raw };
  }
  throw new Error("session event was not the public Unknown variant");
}

async function drainEnd(stream) {
  try {
    for await (const _item of stream) {
      // Deliberately drain until the terminal envelope.
    }
    return stream.end?.reason ?? "completed";
  } catch (error) {
    if (error instanceof StreamError) return error.reason;
    throw error;
  }
}

async function run(payload) {
  const constants = payload.constants;
  if (payload.op === "redaction") {
    const specifierSecret = "provider://conformance-secret";
    const rendererSecret = "renderer-conformance-secret";
    const specifier = new ExternalMachineSpecifier(specifierSecret);
    const renderer = new RendererGrant(
      rendererSecret,
      "unix:///tmp/renderer",
      terminalId("term_66666666666666666666666666666666"),
      ["render"],
      1000,
    );
    return {
      specifier_redacted:
        !specifier.toString().includes(specifierSecret)
        && !JSON.stringify(specifier).includes(specifierSecret),
      renderer_token_redacted:
        !renderer.toString().includes(rendererSecret)
        && !JSON.stringify(renderer).includes(rendererSecret),
    };
  }

  const client = new NodeClient({
    socketPath: payload.socket_path,
    timeoutMs: 15_000,
    randomHex128: () => "a".repeat(32),
  });
  try {
    if (payload.op === "read") {
      const result = await getSession(client, constants).ping();
      return { alive: result.alive, cursor: result.cursor };
    }
    if (payload.op === "mutation-replay") {
      const target = getWorkspace(client, constants);
      const options = {
        idempotencyKey: constants.idempotency_key,
        expectedRevision: decimalString(constants.revision),
      };
      const first = await target.rename(constants.name, options);
      const second = await target.rename(constants.name, options);
      return {
        first: mutationValue(first),
        second: mutationValue(second),
      };
    }
    if (payload.op === "mutation-error") {
      try {
        await getWorkspace(client, constants).rename(constants.name, {
          idempotencyKey: constants.idempotency_key,
          expectedRevision: decimalString(constants.revision),
        });
      } catch (error) {
        if (error instanceof ResourceError) return errorValue(error);
        throw error;
      }
      throw new Error("mutation unexpectedly succeeded");
    }
    if (payload.op === "stream-unknown") {
      const stream = await getSession(client, constants).events();
      const next = await stream.next();
      if (next.done) throw new Error("unknown stream ended before its item");
      const unknown = unknownValue(next.value);
      await stream.next();
      return {
        sequence: next.value.sequence,
        cursor: next.value.cursor,
        ...unknown,
        end: stream.end?.reason ?? "completed",
      };
    }
    if (payload.op === "stream-cancel") {
      const stream = await getSession(client, constants).events();
      await stream.cancel();
      await stream.cancel();
      let count = 0;
      for await (const _item of stream) count += 1;
      return {
        end: stream.end?.reason ?? "canceled",
        items_after_cancel: count,
        cancel_calls: 2,
      };
    }
    if (payload.op === "stream-overflow") {
      const first = await getSession(client, constants).events();
      const firstEnd = await drainEnd(first);
      const second = await getSession(client, constants).events();
      const next = await second.next();
      if (next.done) throw new Error("independent stream ended before its item");
      const secondUnknown = unknownValue(next.value);
      await second.next();
      const control = await getSession(client, constants).ping();
      return {
        first_end: firstEnd,
        second_kind: secondUnknown.kind,
        control_alive: control.alive,
      };
    }
    if (payload.op === "live-flow") {
      const current = client.session(selectCurrent());
      const pinged = Boolean((await current.ping()).alive);
      const name = payload.workspace_name;
      const created = await current.createWorkspace(
        { name, initialContent: "empty" },
        { idempotencyKey: "live-create" },
      );
      const target = created.value.workspace;
      if (!target?.id) throw new Error("workspace.create omitted workspace handle");
      const id = target.id;
      const renamed = await target.rename(`${name}-renamed`, {
        idempotencyKey: "live-rename",
      });
      const listed = (await current.listWorkspaces()).some((item) => item.id === id);
      await target.close({ idempotencyKey: "live-close" });
      const disappeared = (await current.listWorkspaces()).every(
        (item) => item.id !== id,
      );
      return {
        pinged,
        created: true,
        renamed: renamed.value.snapshot?.name === `${name}-renamed`,
        listed,
        closed: true,
        disappeared,
      };
    }
    throw new Error(`unknown adapter operation ${payload.op}`);
  } finally {
    client.close();
  }
}

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const payload = JSON.parse(chunks.join(""));
let response;
try {
  response = {
    contract_version: 2,
    id: payload.id,
    ok: true,
    value: await run(payload),
  };
} catch (error) {
  response = {
    contract_version: 2,
    id: payload.id,
    ok: false,
    error: {
      kind: "adapter",
      message: `${error?.name ?? "Error"}: ${error?.message ?? String(error)}`,
    },
  };
}
process.stdout.write(`${JSON.stringify(response)}\n`);
