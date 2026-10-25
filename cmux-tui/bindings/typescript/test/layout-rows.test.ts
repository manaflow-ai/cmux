import assert from "node:assert/strict";
import test from "node:test";
import { selectCurrent } from "../src/ids.js";
import { Client } from "../src/resources.js";
import type { Transport } from "../src/transport.js";

// A rows-v1 layout document: column 0 has two rows (row 2's row_id is its
// compat chain split), column 1 has one row and no rows field.
const ROWS = [
  { row_id: "split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", height: 600 },
  { row_id: "split_dddddddddddddddddddddddddddddddd", height: 400 },
];
const document = (rows: unknown = ROWS) => ({
  version: 1,
  screen_id: "screen_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  active_pane_id: "pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  zoomed_pane_id: null,
  root: {
    kind: "viewport", base_width: 0.5, columns: [
      {
        column_id: "split_cccccccccccccccccccccccccccccccc", width: 0.5,
        root: {
          kind: "split", split_id: "split_dddddddddddddddddddddddddddddddd", direction: "vertical", ratio: 0.6,
          first: { kind: "leaf", pane_id: "pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", tab_ids: ["tab_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"] },
          second: { kind: "leaf", pane_id: "pane_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", tab_ids: ["tab_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"] },
        },
        rows,
      },
      {
        column_id: "split_ffffffffffffffffffffffffffffffff", width: 0.5,
        root: { kind: "leaf", pane_id: "pane_cccccccccccccccccccccccccccccccc", tab_ids: ["tab_cccccccccccccccccccccccccccccccc"] },
      },
    ],
  },
});

/** Answers screen.layout.export with `value` and records every request. */
class LayoutTransport implements Transport {
  readonly sent: Array<Record<string, any>> = [];
  private message: (json: string) => void = () => {};
  constructor(private readonly value: unknown) {}
  send(json: string): void {
    const request = JSON.parse(json);
    this.sent.push(request);
    const reply = request.operation === "screen.layout.export"
      ? { ok: true, result: this.value }
      : { ok: false, error: { code: "operation.failed", message: "recorded", retryable: false, details: {} } };
    queueMicrotask(() => this.message(JSON.stringify({
      protocol: "cmux.protocol/2", type: "response", id: request.id, ...reply,
    })));
  }
  onMessage(handler: (json: string) => void): () => void { this.message = handler; return () => {}; }
  onClose(): () => void { return () => {}; }
  onError(): () => void { return () => {}; }
  close(): void {}
}

test("layout documents decode a column's rows and send them back", async () => {
  const transport = new LayoutTransport(document());
  const client = new Client({ transport });
  try {
    const layout = await client.session(selectCurrent()).workspace(selectCurrent()).screen(selectCurrent()).exportLayout();
    assert.equal(layout.root.kind, "viewport");
    if (layout.root.kind !== "viewport") return;
    assert.deepEqual(layout.root.columns[0]!.rows, [
      { rowId: "split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", height: 600 },
      { rowId: "split_dddddddddddddddddddddddddddddddd", height: 400 },
    ]);
    assert.equal(layout.root.columns[1]!.rows, undefined, "a one-row column has no rows");
    await assert.rejects(client.session(selectCurrent()).workspace(selectCurrent()).applyLayout({ layout }));
    const apply = transport.sent.find((request) => request.operation === "workspace.layout.apply");
    assert.deepEqual(apply?.params.layout.root.columns[0].rows, ROWS);
    assert.equal("rows" in apply?.params.layout.root.columns[1], false);
  } finally {
    client.close();
  }
});

test("layout rows keep row 1 without an id and refuse bad rows", async () => {
  const first = new LayoutTransport(document([{ height: 500 }, ROWS[1]]));
  const client = new Client({ transport: first });
  try {
    const layout = await client.session(selectCurrent()).workspace(selectCurrent()).screen(selectCurrent()).exportLayout();
    assert.ok(layout.root.kind === "viewport");
    assert.deepEqual(layout.root.columns[0]!.rows![0], { height: 500 });
  } finally {
    client.close();
  }
  for (const rows of [
    [{ ...ROWS[0], width: 1 }, ROWS[1]],
    [{ ...ROWS[0], height: 50 }, ROWS[1]],
    [{ row_id: ROWS[0]!.row_id }, ROWS[1]],
    "rows",
  ]) {
    const bad = new Client({ transport: new LayoutTransport(document(rows)) });
    try {
      await assert.rejects(bad.session(selectCurrent()).workspace(selectCurrent()).screen(selectCurrent()).exportLayout());
    } finally {
      bad.close();
    }
  }
});
