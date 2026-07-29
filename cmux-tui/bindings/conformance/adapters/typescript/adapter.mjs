#!/usr/bin/env node
// Public resource conformance adapter for the TypeScript Node entrypoint.

import {
  ExternalMachineSpecifier,
  RendererGrant,
  ResourceError,
  StreamError,
  decimalString,
  selectCurrent,
  selectName,
  sessionId,
  terminalId,
  workspaceId,
} from "../../../typescript/dist/src/index.js";
import {
  Client as ResourceClient,
  WebSocketTransport,
} from "../../../typescript/dist/src/browser.js";
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

function makeClient(payload) {
  if (payload.transport === "websocket") {
    if (typeof payload.websocket_url !== "string") {
      throw new TypeError("websocket_url must be a string");
    }
    if (typeof payload.websocket_token !== "string") {
      throw new TypeError("websocket_token must be a string");
    }
    return new ResourceClient({
      transport: new WebSocketTransport(payload.websocket_url, {
        authToken: payload.websocket_token,
      }),
      timeoutMs: 15_000,
      randomHex128: () => "a".repeat(32),
    });
  }
  if (payload.transport !== undefined && payload.transport !== "unix") {
    throw new TypeError(`unsupported transport ${String(payload.transport)}`);
  }
  return new NodeClient({
    socketPath: payload.socket_path,
    timeoutMs: 15_000,
    randomHex128: () => "a".repeat(32),
  });
}

function liveSession(client) {
  return client.session(selectCurrent());
}

async function workspaceRows(current) {
  const rows = new Map();
  for (const item of await current.listWorkspaces()) {
    const snapshot = item.snapshot ?? await item.refresh();
    rows.set(snapshot.id, snapshot.name);
  }
  return rows;
}

function candidateIds(error) {
  if (
    !error.details
    || typeof error.details !== "object"
    || !Array.isArray(error.details.candidates)
  ) {
    return [];
  }
  return error.details.candidates.filter(
    (candidate) => typeof candidate === "string",
  );
}

async function liveSetup(client, baseName, keyPrefix) {
  const current = liveSession(client);
  const pinged = Boolean((await current.ping()).alive);
  const stableCreated = await current.createWorkspace(
    { name: baseName, initialContent: "empty" },
    { idempotencyKey: `${keyPrefix}-stable-create` },
  );
  const stable = stableCreated.value.workspace;
  if (!stable?.id) throw new Error("workspace.create omitted stable workspace handle");
  const stableId = stable.id;
  const stableRenamedName = `${baseName}-renamed`;
  const renamed = await stable.rename(stableRenamedName, {
    idempotencyKey: `${keyPrefix}-stable-rename`,
  });

  const duplicateName = `${baseName}-duplicate`;
  const duplicateIds = [];
  for (const suffix of ["a", "b"]) {
    const created = await current.createWorkspace(
      { name: duplicateName, initialContent: "empty" },
      { idempotencyKey: `${keyPrefix}-duplicate-${suffix}` },
    );
    const duplicate = created.value.workspace;
    if (!duplicate?.id) {
      throw new Error("workspace.create omitted duplicate workspace handle");
    }
    duplicateIds.push(duplicate.id);
  }

  let ambiguityCode = "";
  let ambiguityCandidates = [];
  try {
    await current.workspace(selectName(duplicateName)).rename(
      `${baseName}-must-not-apply`,
      { idempotencyKey: `${keyPrefix}-ambiguous-rename` },
    );
    throw new Error("duplicate workspace selector unexpectedly mutated");
  } catch (error) {
    if (!(error instanceof ResourceError)) throw error;
    ambiguityCode = error.code;
    ambiguityCandidates = candidateIds(error);
  }
  const rows = await workspaceRows(current);
  return {
    pinged,
    stable_id: stableId,
    stable_renamed: renamed.value.snapshot?.name === stableRenamedName,
    duplicate_ids: duplicateIds,
    ambiguity_code: ambiguityCode,
    ambiguity_preserved_all_candidates:
      ambiguityCandidates.length === duplicateIds.length
      && duplicateIds.every((identifier) => ambiguityCandidates.includes(identifier)),
    no_mutation:
      duplicateIds.every((identifier) => rows.get(identifier) === duplicateName)
      && ![...rows.values()].includes(`${baseName}-must-not-apply`),
  };
}

async function liveRestart(
  client,
  baseName,
  keyPrefix,
  expectedStableId,
  expectedDuplicateIds,
) {
  const current = liveSession(client);
  const rows = await workspaceRows(current);
  const expectedIds = [expectedStableId, ...expectedDuplicateIds];
  const sameIds = expectedIds.every((identifier) => rows.has(identifier));
  const stableNamePreserved =
    rows.get(expectedStableId) === `${baseName}-renamed`;
  const duplicatesPreserved = expectedDuplicateIds.every(
    (identifier) => rows.get(identifier) === `${baseName}-duplicate`,
  );

  await current.workspace(workspaceId(expectedStableId)).close({
    idempotencyKey: `${keyPrefix}-close-stable`,
  });
  for (const [index, identifier] of expectedDuplicateIds.entries()) {
    await current.workspace(workspaceId(identifier)).close({
      idempotencyKey: `${keyPrefix}-close-${index === 0 ? "a" : "b"}`,
    });
  }
  const remaining = await workspaceRows(current);
  return {
    same_ids: sameIds,
    stable_name_preserved: stableNamePreserved,
    duplicates_preserved: duplicatesPreserved,
    closed: true,
    disappeared: expectedIds.every((identifier) => !remaining.has(identifier)),
  };
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

  const client = makeClient(payload);
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
    if (payload.op === "live-setup") {
      return await liveSetup(client, payload.workspace_name, payload.key_prefix);
    }
    if (payload.op === "live-restart") {
      if (
        !Array.isArray(payload.expected_duplicate_ids)
        || !payload.expected_duplicate_ids.every(
          (identifier) => typeof identifier === "string",
        )
      ) {
        throw new TypeError("expected_duplicate_ids must be a string array");
      }
      return await liveRestart(
        client,
        payload.workspace_name,
        payload.key_prefix,
        payload.expected_stable_id,
        payload.expected_duplicate_ids,
      );
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
