import assert from "node:assert/strict";
import test from "node:test";
import { decodeProtocolEvent } from "../src/raw/protocol-codec.js";
import { parseWireJson } from "../src/wire-json.js";

test("native inventory events preserve owner, lease and exact UInt64 wire revision", () => {
  const owner = `machine_${"a".repeat(32)}`;
  const watch = `inventory_watch_${"b".repeat(32)}`;
  const changed = decodeProtocolEvent(parseWireJson(
    `{"event":"agent-inventory-changed","machine":"${owner}","watch_id":"${watch}","revision":18446744073709551615}`,
  ));
  assert.equal(changed.machine, owner);
  assert.equal(changed.watch_id, watch);
  assert.equal(changed.revision, 18446744073709551615n);
  assert.throws(() => decodeProtocolEvent({
    event: "agent-inventory-changed", machine: owner, revision: 1,
  }), /watch_id/);
  const ended = decodeProtocolEvent({
    event: "agent-inventory-watch-ended", machine: owner, watch_id: watch,
    reason: "agent_inventory.unavailable",
  });
  assert.equal(ended.watch_id, watch);
  assert.equal(ended.reason, "agent_inventory.unavailable");
});
