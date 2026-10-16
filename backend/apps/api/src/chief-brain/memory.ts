import { finishLine, initSync, OptChat, sizeCheck } from "./optchat-wasm/optchat_wasm.js";
import wasmModule from "./optchat-wasm/optchat_wasm_bg.wasm";

/**
 * One chat's OptChat memory (spec sections 2-6) in Durable Object SQLite, driven by the Rust core
 * compiled to WebAssembly. The core owns the fold, the pump order (rule 3), addressing, zoom and
 * the size loop; this class owns storage and dates.
 *
 * Storage replaces the spec's JSONL files with two append-only tables. A DO SQLite write is
 * durable once the output gate opens, which is the DO equivalent of write + fsync, and the DO is
 * the single writer, which replaces the socket lock.
 */

let initialized = false;
function ensureWasm(): void {
  if (initialized) return;
  initSync({ module: wasmModule });
  initialized = true;
}

export type Kind = "user" | "talk" | "tool" | "echo" | "note";

export interface LogEntry {
  readonly i: number;
  readonly kind: Kind;
  readonly text: string;
  readonly size: number;
  readonly date: string;
}

export type Work = { kind: "free"; l: number; i: number; text: string } | { kind: "model"; l: number; i: number };

export interface CompactRequest {
  readonly system: string;
  readonly context: string;
  readonly marks: ReadonlyArray<number>;
  readonly step: string;
  readonly cut: string | null;
  readonly room: number;
}

/** Spec section 1 constants that live on the host side. */
export const CAP = 30_000;
export const JOBS = 8;
export const TRIES = 5;
export const RETRY_MS = 10_000;

const encoder = new TextEncoder();
const decoder = new TextDecoder();
export const bytes = (s: string) => encoder.encode(s).length;

/** Cuts UTF-8 `text` at byte offsets (the core's cache marks) into pieces. */
export function cutAtMarks(text: string, marks: ReadonlyArray<number>): string[] {
  const raw = encoder.encode(text);
  const pieces: string[] = [];
  let start = 0;
  for (const m of marks) {
    if (m <= start || m >= raw.length) continue;
    pieces.push(decoder.decode(raw.subarray(start, m)));
    start = m;
  }
  pieces.push(decoder.decode(raw.subarray(start)));
  return pieces.filter((p) => p.length > 0);
}

/**
 * Spec 7: a tool result over CAP characters keeps its head and tail, with a note of the cut.
 * Characters are Unicode code points (as the Rust host counts them), never split.
 */
export function capText(text: string): string {
  if (text.length <= CAP) return text; // at most CAP UTF-16 units, so at most CAP characters
  const chars = Array.from(text);
  if (chars.length <= CAP) return text;
  const keep = CAP / 2;
  return `${chars.slice(0, keep).join("")}\n[... ${chars.length - CAP} of ${chars.length} characters cut ...]\n${chars.slice(-keep).join("")}`;
}

export class Memory {
  private core: OptChat;
  private readonly store: {
    message: (i: number) => { kind: string; text: string };
    node: (l: number, i: number) => string | undefined;
  };

  constructor(
    private readonly sql: SqlStorage,
    private readonly budget = 0,
  ) {
    ensureWasm();
    sql.exec(
      `CREATE TABLE IF NOT EXISTS oc_message (i INTEGER PRIMARY KEY, kind TEXT NOT NULL, text TEXT NOT NULL, size INTEGER NOT NULL, date TEXT NOT NULL)`,
    );
    sql.exec(
      `CREATE TABLE IF NOT EXISTS oc_node (l INTEGER NOT NULL, i INTEGER NOT NULL, text TEXT NOT NULL, size INTEGER NOT NULL, PRIMARY KEY (l, i))`,
    );
    this.store = {
      message: (i) => {
        const row = sql.exec<{ kind: string; text: string }>(`SELECT kind, text FROM oc_message WHERE i = ?`, i).toArray()[0];
        if (!row) throw new Error(`message ${i} is not stored`);
        return { kind: row.kind, text: row.text };
      },
      node: (l, i) =>
        sql.exec<{ text: string }>(`SELECT text FROM oc_node WHERE l = ? AND i = ?`, l, i).toArray()[0]?.text,
    };
    this.core = this.load();
  }

  /** Spec 5.2 "at load": the view is folded again from message 0 over the stored nodes. */
  private load(): OptChat {
    const t = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM oc_message`).one().n);
    const built = this.sql
      .exec<{ l: number; i: number; size: number }>(`SELECT l, i, size FROM oc_node ORDER BY l, i`)
      .toArray()
      .map((r) => [Number(r.l), Number(r.i), Number(r.size)]);
    return t === 0 && built.length === 0 ? new OptChat(this.budget) : OptChat.load(t, JSON.stringify(built), this.budget);
  }

  /** Re-folds from storage, as after a restart (tests use it to compare views). */
  reload(): void {
    this.core.free();
    this.core = this.load();
  }

  len(): number {
    return this.core.len();
  }

  /** Appends one message to the log, verbatim, and to the view. */
  append(kind: Kind, text: string, date = new Date()): LogEntry {
    const i = this.core.len();
    const size = bytes(`${kind}: ${text}`);
    const iso = date.toISOString();
    this.sql.exec(`INSERT INTO oc_message (i, kind, text, size, date) VALUES (?, ?, ?, ?, ?)`, i, kind, text, size, iso);
    const got = this.core.append();
    if (got !== i) throw new Error(`core appended ${got}, store has ${i}`);
    return { i, kind, text, size, date: iso };
  }

  entries(after: number, limit: number): LogEntry[] {
    return this.sql
      .exec<Record<string, SqlStorageValue>>(
        `SELECT i, kind, text, size, date FROM oc_message WHERE i >= ? ORDER BY i LIMIT ?`,
        after,
        limit,
      )
      .toArray()
      .map((r) => ({ i: Number(r.i), kind: r.kind as Kind, text: String(r.text), size: Number(r.size), date: String(r.date) }));
  }

  /** Work the compactor may start now; free nodes are stored here (the core already built them). */
  pump(): Work[] {
    const work = JSON.parse(this.core.pump(this.store)) as Work[];
    for (const w of work) if (w.kind === "free") this.saveNode(w.l, w.i, w.text);
    return work.filter((w) => w.kind === "model");
  }

  compactRequest(l: number, i: number, prompt: string, agent: string): CompactRequest {
    return JSON.parse(this.core.compactRequest(this.store, l, i, prompt, "", agent)) as CompactRequest;
  }

  /** Stores a model-built node and refits the view. */
  complete(l: number, i: number, text: string): void {
    this.saveNode(l, i, text);
    this.core.complete(l, i, text);
  }

  fail(l: number, i: number): void {
    this.core.fail(l, i);
  }

  private saveNode(l: number, i: number, text: string): void {
    this.sql.exec(
      `INSERT INTO oc_node (l, i, text, size) VALUES (?, ?, ?, ?) ON CONFLICT (l, i) DO NOTHING`,
      l,
      i,
      text,
      bytes(text),
    );
  }

  settled(): boolean {
    return this.core.settled();
  }

  /** The rendered `<chat>` view and its cache marks (UTF-8 byte offsets). */
  render(): { text: string; marks: number[] } {
    return JSON.parse(this.core.renderView(this.store)) as { text: string; marks: number[] };
  }

  /**
   * The turn's cache-stable input (OptChat 5a, optchat-core `turn_input`): the frozen view's 4-line
   * blocks, then the delta blocks (every message after the view's front, the new ones included). The
   * frozen view is kept here and given back next turn; the core decides when to render it again.
   */
  turnInput(): string[] {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS oc_frozen (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)`);
    const prior = this.sql.exec<{ json: string }>(`SELECT json FROM oc_frozen WHERE id = 1`).toArray()[0]?.json ?? "";
    const out = JSON.parse(this.core.turnInput(this.store, prior)) as { frozen: unknown; rerendered: boolean; view: string[]; delta: string[] };
    this.sql.exec(`INSERT INTO oc_frozen (id, json) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET json = excluded.json`, JSON.stringify(out.frozen));
    return [...out.view, ...out.delta];
  }

  viewParts(): Array<{ l: number; i: number; name: string }> {
    return JSON.parse(this.core.view()) as Array<{ l: number; i: number; name: string }>;
  }

  viewSize(): number {
    return this.core.viewSize();
  }

  /** Every stored node, by level then index (for the browse page). */
  nodes(): Array<{ l: number; i: number; text: string; size: number }> {
    return this.sql
      .exec<Record<string, SqlStorageValue>>(`SELECT l, i, text, size FROM oc_node ORDER BY l, i`)
      .toArray()
      .map((r) => ({ l: Number(r.l), i: Number(r.i), text: String(r.text), size: Number(r.size) }));
  }

  /** The text of node (l, i) if built. */
  node(l: number, i: number): string | undefined {
    return this.store.node(l, i);
  }

  nodeCount(): number {
    return Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM oc_node`).one().n);
  }

  zoom(id: number, n: number): string {
    try {
      return this.core.zoom(this.store, id, n);
    } catch (e) {
      const msg = (e as Error).message ?? String(e);
      return msg.startsWith("No line") ? msg : `No line ${id}+${n}.`;
    }
  }

  /** Local date and time of message `id`. */
  date(id: number, timeZone: string): string {
    const row = this.sql.exec<{ date: string }>(`SELECT date FROM oc_message WHERE i = ?`, id).toArray()[0];
    if (!row) return `No message ${id}.`;
    return new Intl.DateTimeFormat("en-CA", {
      timeZone,
      dateStyle: "full",
      timeStyle: "long",
    }).format(new Date(row.date));
  }
}

export { finishLine, sizeCheck };
