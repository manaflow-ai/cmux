import assert from "node:assert/strict";
import test from "node:test";
import {
  COMMAND_METADATA,
  EVENT_METADATA,
  MUX_PROTOCOL_VERSION,
  PROFILES,
  SDK_IR_SHA256,
  SDK_SCHEMA_VERSION,
} from "cmux-sdk/raw";

test("generated protocol coverage matches the canonical v12 IR", () => {
  assert.equal(MUX_PROTOCOL_VERSION, 12);
  assert.equal(SDK_SCHEMA_VERSION, 2);
  assert.equal(Object.keys(COMMAND_METADATA).length, 103);
  assert.equal(Object.keys(EVENT_METADATA).length, 46);
  assert.equal(SDK_IR_SHA256.length, 64);
  assert.deepEqual(Object.keys(PROFILES).sort(), [
    "control",
    "frontend",
    "local-admin",
    "provider-authority",
  ]);
});

test("generated active events exclude serialized-only shapes", () => {
  const emitted = Object.entries(EVENT_METADATA)
    .filter(([, metadata]) => metadata.emission === "emitted")
    .map(([name]) => name);
  assert.equal(emitted.length, 45);
  assert.equal(EVENT_METADATA["client-list-invalidated"].emission, "serialized-never-emitted");
  assert.equal(emitted.includes("client-list-invalidated"), false);
});

test("every generated command carries authority and version metadata", () => {
  for (const [command, metadata] of Object.entries(COMMAND_METADATA)) {
    assert.ok(command.length > 0);
    assert.ok(metadata.since >= 5 && metadata.since <= MUX_PROTOCOL_VERSION);
    assert.ok(metadata.authority in PROFILES);
  }
});

test("generated command metadata exposes gated request fields", () => {
  for (const command of [
    "browser-frame-presented",
    "browser-mouse-guarded",
    "browser-wheel-guarded",
  ] as const) {
    assert.equal(
      COMMAND_METADATA[command].capability,
      "browser-pointer-frame-guard-v1",
    );
    assert.equal(COMMAND_METADATA[command].since, 10);
  }
  assert.deepEqual(COMMAND_METADATA.send.fields.paste, {
    since: 7,
    capability: null,
  });
  assert.deepEqual(COMMAND_METADATA.run.fields.key, {
    since: 9,
    capability: null,
  });
  for (const field of [
    "cursor",
    "selection_bg",
    "selection_fg",
    "cursor_style",
    "cursor_blink",
    "palette",
    "complete",
  ] as const) {
    assert.deepEqual(COMMAND_METADATA["set-default-colors"].fields[field], {
      since: 9,
      capability: null,
    });
  }
  assert.deepEqual(COMMAND_METADATA.subscribe.fields.surface, {
    since: 9,
    capability: "surface-subscribe-filter",
  });
  for (const field of ["cols", "rows"] as const) {
    assert.deepEqual(COMMAND_METADATA["attach-surface"].fields[field], {
      since: null,
      capability: "attach-initial-size",
    });
  }
  for (const command of [
    "close-workspace",
    "rename-workspace",
    "move-workspace",
  ] as const) {
    assert.deepEqual(COMMAND_METADATA[command].fields.key, {
      since: 7,
      capability: "workspace-registry-v1",
    });
  }
  assert.deepEqual(COMMAND_METADATA["move-workspace"].fields.expected_revision, {
    since: 7,
    capability: null,
  });
});
