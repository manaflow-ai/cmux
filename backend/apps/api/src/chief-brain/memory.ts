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

export type Kind = "user" | "talk" | "tool" | "echo" | "note" | "ai";

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
export const bytes = (s: string) => encoder.encode(s).length;

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
  /** How the memory was loaded at the last start: from its checkpoint (O(view + frontier + new)), or folded. */
  loaded: "resumed" | "folded" = "folded";
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
    sql.exec(`CREATE TABLE IF NOT EXISTS oc_frozen (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)`);
    // Where the core stands (optchat-core Checkpoint, as optchat-host's memory/checkpoint): saved after
    // every change, so a start resumes from it and never folds the whole log again (spec 3.2).
    sql.exec(`CREATE TABLE IF NOT EXISTS oc_checkpoint (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)`);
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

  /**
   * At start: resume from the saved checkpoint (the views as they were, the frontier nodes, and the
   * messages logged after it), reading message and node texts only when a merge or a render needs
   * them. Without a usable checkpoint (a first start, an older store) the view is folded from every
   * node's size once, and its checkpoint saved, so the next start resumes. Either way the core is lazy.
   */
  private load(): OptChat {
    const t = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM oc_message`).one().n);
    if (t === 0 && this.nodeCount() === 0) {
      this.loaded = "folded";
      const fresh = new OptChat(this.budget);
      fresh.makeLazy();
      return fresh;
    }
    const saved = this.sql.exec<{ json: string }>(`SELECT json FROM oc_checkpoint WHERE id = 1`).toArray()[0]?.json;
    if (saved) {
      // A bad checkpoint or a failed read never stops the object: it folds instead (logged, no text).
      try {
      const low = ((JSON.parse(saved) as { low?: unknown }).low ?? []) as number[];
      const frontier: Array<[number, number, number]> = [];
      const top = Number(this.sql.exec<{ n: number | null }>(`SELECT MAX(l) AS n FROM oc_node`).one().n ?? -1);
      for (let l = 0; l <= top; l++) {
        for (const r of this.sql.exec<{ i: number; size: number }>(`SELECT i, size FROM oc_node WHERE l = ? AND i >= ?`, l, low[l] ?? 0)) frontier.push([l, Number(r.i), Number(r.size)]);
      }
      const resumed = OptChat.resume(saved, t, JSON.stringify(frontier), this.budget, this.store);
      if (resumed) {
        this.loaded = "resumed";
        // Messages logged after the checkpoint were appended as live: save where it stands now.
        if (Number((JSON.parse(saved) as { t?: unknown }).t ?? t) < t) this.saveCheckpoint(resumed);
        return resumed;
      }
      } catch (e) {
        console.warn(JSON.stringify({ msg: "chief_brain.memory_resume_failed", error: String((e as Error)?.message ?? e).slice(0, 200) }));
      }
    }
    const built = this.sql
      .exec<{ l: number; i: number; size: number }>(`SELECT l, i, size FROM oc_node ORDER BY l, i`)
      .toArray()
      .map((r) => [Number(r.l), Number(r.i), Number(r.size)]);
    const folded = OptChat.load(t, JSON.stringify(built), this.budget);
    folded.makeLazy();
    this.loaded = "folded";
    this.saveCheckpoint(folded);
    return folded;
  }

  private saveCheckpoint(core: OptChat = this.core): void {
    this.sql.exec(`INSERT INTO oc_checkpoint (id, json) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET json = excluded.json`, core.checkpoint());
  }

  /** Counts the times the log was cut back (an import's undo): a node built before the cut covers rows that are gone. */
  generation = 0

  /** The log was cut back in storage (memory-import.ts `undoBatch`): re-fold, and make every node still being built stale. */
  rewound(): void {
    this.generation++
    this.reload()
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
    // The core can be ahead of the log after a rolled-back transaction: fold back to the store first.
    const stored = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM oc_message`).one().n);
    if (stored !== this.core.len()) this.reload();
    const i = this.core.len();
    const size = bytes(`${kind}: ${text}`);
    const iso = date.toISOString();
    this.sql.exec(`INSERT INTO oc_message (i, kind, text, size, date) VALUES (?, ?, ?, ?, ?)`, i, kind, text, size, iso);
    const got = this.core.appendIn(this.store);
    if (got !== i) throw new Error(`core appended ${got}, store has ${i}`);
    this.saveCheckpoint();
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
    if (work.some((w) => w.kind === "free")) this.saveCheckpoint();
    return work.filter((w) => w.kind === "model");
  }

  compactRequest(l: number, i: number, prompt: string, agent: string): CompactRequest {
    return JSON.parse(this.core.compactRequest(this.store, l, i, prompt, "", agent)) as CompactRequest;
  }

  /** Stores a model-built node and refits the view. */
  complete(l: number, i: number, text: string, generation: number = this.generation): void {
    // Built over rows an undo has since removed: dropped (the compactor builds the node again from what stays).
    if (generation !== this.generation) return
    this.saveNode(l, i, text);
    this.core.completeIn(l, i, text, this.store);
    this.saveCheckpoint();
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

  /** The first message whose view line is not built yet, or the log's length (the reference client's `Memory.first`). */
  first(): number {
    return this.core.first();
  }

  /** The rendered `<chat>` view and its cache marks (indices into the JS string `text`, UTF-16 code units). */
  render(): { text: string; marks: number[] } {
    return JSON.parse(this.core.renderView(this.store)) as { text: string; marks: number[] };
  }

  /**
   * The turn's input (optchat-core `turn_input`), as 4-line view blocks then the delta blocks.
   * `fresh` (every message before the new ones is summarized): the view is rendered again, so it
   * shows every message before the new ones as built lines and the delta holds only the new
   * messages, as the reference client builds each call (`Memory.view(mem, from)` + the new messages).
   * Not fresh (the compactor is behind): the view rendered last is given back, with every message
   * since as a whole delta line (OptChat 5a), so nothing unsummarized is hidden behind a placeholder.
   * The rendered view is kept here either way.
   */
  turnInput(newMessages: number, fresh = false): string[] {
    const prior = fresh ? "" : (this.sql.exec<{ json: string }>(`SELECT json FROM oc_frozen WHERE id = 1`).toArray()[0]?.json ?? "");
    let out: { frozen: unknown; rerendered: boolean; view: string[]; delta: string[] };
    try {
      out = JSON.parse(this.core.turnInput(this.store, prior, newMessages)) as typeof out;
    } catch (e) {
      // The caller's transaction rolls back the messages this turn appended; the core holds them
      // already, so it re-folds from storage once the rollback is done (a later append would refuse).
      queueMicrotask(() => this.reload());
      throw e;
    }
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
