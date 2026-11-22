import assert from "node:assert/strict";
import test from "node:test";
import { decodeCommandResult } from "../src/raw/protocol-codec.js";

function sizeState(deviceKind: unknown) {
  return {
    state: {
      generation: 1,
      cols: 80,
      rows: 24,
      reason: "latest",
      owners: ["c1"],
      policy: { mode: "latest", priority: [], fixed: null },
      participants: [{
        id: "c1",
        user_id: "u1",
        display_name: null,
        device_kind: deviceKind,
        device_name: null,
        device_id: null,
        via: null,
        viewport: null,
        counts: true,
        counts_override: null,
        priority_key: "u1/x",
      }],
    },
    self_participant: "c1",
  };
}

function decodedKind(deviceKind: unknown): unknown {
  const decoded = decodeCommandResult("get-size-state", sizeState(deviceKind)) as {
    state: { participants: Array<{ device_kind: unknown }> };
  };
  return decoded.state.participants[0]?.device_kind;
}

test("size-state device kinds include linux and windows", () => {
  for (const kind of ["mac", "iphone", "ipad", "tui", "browser", "linux", "windows", "unknown"]) {
    assert.equal(decodedKind(kind), kind);
  }
});

test("an unknown device kind decodes as a generic client", () => {
  assert.equal(decodedKind("quantum"), "unknown");
  assert.throws(() => decodedKind(7), /enum/);
});
