import { existsSync, readFileSync } from "node:fs";
import { mkdir, rename, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { AgentEvent, OptionValue, SessionStatus } from "./types";

const STORE_VERSION = 1;
const DEFAULT_MAX_EVENTS = 5_000;
const DEFAULT_DEBOUNCE_MS = 100;

export interface DurableTaskRecord {
  id: string;
  conversationId: string;
  provider: string;
  cwd: string;
  title: string;
  status: SessionStatus;
  createdAt: number;
  updatedAt: number;
  autoApprove: boolean;
  startOptions: Record<string, OptionValue>;
  parentSessionId?: string;
  parentConversationId?: string;
  startRequestId?: string;
  events: AgentEvent[];
}

interface StoreFile {
  version: number;
  tasks: DurableTaskRecord[];
}

export interface DurableTaskStoreOptions {
  maxEvents?: number;
  debounceMs?: number;
}

/**
 * A small, atomic task journal for the agent-chat sidecar.
 *
 * Provider process handles intentionally do not belong here. The journal is
 * the durable identity/transcript boundary: a later runtime can inspect and
 * replay a task even when the provider process that produced it is gone.
 */
export class DurableTaskStore {
  readonly path: string;
  private readonly maxEvents: number;
  private readonly debounceMs: number;
  private readonly records = new Map<string, DurableTaskRecord>();
  private writeChain: Promise<void> = Promise.resolve();
  private writeTimer: ReturnType<typeof setTimeout> | null = null;
  private dirty = false;

  constructor(path: string, options: DurableTaskStoreOptions = {}) {
    this.path = path;
    this.maxEvents = Math.max(1, Math.floor(options.maxEvents ?? DEFAULT_MAX_EVENTS));
    this.debounceMs = Math.max(0, Math.floor(options.debounceMs ?? DEFAULT_DEBOUNCE_MS));
    this.load();
  }

  get(id: string): DurableTaskRecord | undefined {
    const record = this.records.get(id);
    return record ? cloneRecord(record) : undefined;
  }

  list(): DurableTaskRecord[] {
    return [...this.records.values()]
      .sort((a, b) => b.createdAt - a.createdAt)
      .map(cloneRecord);
  }

  upsert(record: DurableTaskRecord): void {
    if (!record.id || !record.conversationId || !record.provider || !record.cwd) {
      throw new Error("durable task record is missing identity fields");
    }
    const events = record.events.slice(-this.maxEvents).map(cloneEvent);
    this.records.set(record.id, {
      ...record,
      startOptions: { ...record.startOptions },
      events,
      updatedAt: Number.isFinite(record.updatedAt) ? record.updatedAt : Date.now(),
    });
    this.markDirty();
  }

  remove(id: string): void {
    if (this.records.delete(id)) this.markDirty();
  }

  /** Wait until all currently queued journal writes have reached disk. */
  async flush(): Promise<void> {
    for (;;) {
      if (this.writeTimer) {
        clearTimeout(this.writeTimer);
        this.writeTimer = null;
      }
      if (this.dirty) this.beginWrite();
      await this.writeChain;
      if (!this.dirty && !this.writeTimer) return;
    }
  }

  private load(): void {
    if (!this.path || !existsSync(this.path)) return;
    try {
      const raw = JSON.parse(readFileSync(this.path, "utf8")) as StoreFile;
      if (!raw || raw.version !== STORE_VERSION || !Array.isArray(raw.tasks)) return;
      for (const value of raw.tasks) {
        const record = parseRecord(value);
        if (record) this.records.set(record.id, record);
      }
    } catch {
      // A corrupt journal must not prevent the sidecar from starting. The
      // next successful write atomically replaces it with a valid snapshot.
    }
  }

  private markDirty(): void {
    if (!this.path) return;
    this.dirty = true;
    if (this.writeTimer || this.debounceMs === 0) {
      if (this.debounceMs === 0) this.beginWrite();
      return;
    }
    this.writeTimer = setTimeout(() => {
      this.writeTimer = null;
      this.beginWrite();
    }, this.debounceMs);
  }

  private beginWrite(): void {
    if (!this.path || !this.dirty) return;
    this.dirty = false;
    const payload: StoreFile = {
      version: STORE_VERSION,
      tasks: this.list(),
    };
    this.writeChain = this.writeChain
      .catch(() => {})
      .then(async () => {
        const directory = dirname(this.path);
        await mkdir(directory, { recursive: true });
        const tmp = join(directory, `${basename(this.path)}.${process.pid}.${crypto.randomUUID()}.tmp`);
        try {
          await writeFile(tmp, JSON.stringify(payload) + "\n", "utf8");
          await rename(tmp, this.path);
        } finally {
          // rename removes tmp on success; a failed write should not leave
          // unbounded junk behind.
          try {
            await unlink(tmp);
          } catch {
            // Best effort cleanup only.
          }
        }
      });
  }
}

function cloneEvent(event: AgentEvent): AgentEvent {
  return JSON.parse(JSON.stringify(event)) as AgentEvent;
}

function cloneRecord(record: DurableTaskRecord): DurableTaskRecord {
  return {
    ...record,
    startOptions: { ...record.startOptions },
    events: record.events.map(cloneEvent),
  };
}

function parseRecord(value: unknown): DurableTaskRecord | null {
  if (!value || typeof value !== "object") return null;
  const record = value as Partial<DurableTaskRecord>;
  if (typeof record.id !== "string" || typeof record.conversationId !== "string" || typeof record.provider !== "string" || typeof record.cwd !== "string") return null;
  if (typeof record.title !== "string" || typeof record.status !== "string") return null;
  if (!Array.isArray(record.events) || !record.events.every((event) => event && typeof event === "object" && typeof (event as AgentEvent).kind === "string")) return null;
  return {
    id: record.id,
    conversationId: record.conversationId,
    provider: record.provider,
    cwd: record.cwd,
    title: record.title,
    status: record.status as SessionStatus,
    createdAt: typeof record.createdAt === "number" ? record.createdAt : 0,
    updatedAt: typeof record.updatedAt === "number" ? record.updatedAt : 0,
    autoApprove: record.autoApprove !== false,
    startOptions: record.startOptions && typeof record.startOptions === "object" ? { ...record.startOptions } : {},
    ...(typeof record.parentSessionId === "string" ? { parentSessionId: record.parentSessionId } : {}),
    ...(typeof record.parentConversationId === "string" ? { parentConversationId: record.parentConversationId } : {}),
    ...(typeof record.startRequestId === "string" ? { startRequestId: record.startRequestId } : {}),
    events: record.events.map(cloneEvent),
  };
}
