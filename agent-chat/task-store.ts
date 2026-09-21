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
        if (record) {
          // A journal written with a larger limit can be reopened with a
          // smaller one. Apply the active limit while recovering as well as
          // while upserting, so reads and subsequent snapshots stay bounded.
          record.events = record.events.slice(-this.maxEvents);
          this.records.set(record.id, record);
        }
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
      })
      .catch((error) => {
        // Keep a failed snapshot dirty so a later flush or mutation can retry.
        // Do not clear a newer dirty flag set while this write was pending.
        this.dirty = true;
        throw error;
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
  if (typeof record.title !== "string" || !isSessionStatus(record.status)) return null;
  if (!Array.isArray(record.events) || !record.events.every(isAgentEvent)) return null;
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

function isSessionStatus(value: unknown): value is SessionStatus {
  return value === "idle" || value === "running" || value === "exited" || value === "error";
}

function isString(value: unknown): value is string {
  return typeof value === "string";
}

function isBoolean(value: unknown): value is boolean {
  return typeof value === "boolean";
}

function isOptionChoice(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const choice = value as Record<string, unknown>;
  if (!isString(choice.value) || !isString(choice.label)) return false;
  if (choice.description !== undefined && !isString(choice.description)) return false;
  if (choice.disabled !== undefined && !isBoolean(choice.disabled)) return false;
  if (choice.disabledReason !== undefined && !isString(choice.disabledReason)) return false;
  if (choice.defaultEffort !== undefined && !isString(choice.defaultEffort)) return false;
  return choice.efforts === undefined || (Array.isArray(choice.efforts) && choice.efforts.every(isOptionChoice));
}

function isSessionOption(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const option = value as Record<string, unknown>;
  if (!isString(option.id) || !isString(option.label)) return false;
  if (option.kind !== "select" && option.kind !== "toggle") return false;
  if (typeof option.value !== "string" && typeof option.value !== "boolean") return false;
  if (option.role !== undefined && !["effort", "thinking-budget", "approval", "context"].includes(option.role as string)) return false;
  if (option.disabled !== undefined && !isBoolean(option.disabled)) return false;
  if (option.description !== undefined && !isString(option.description)) return false;
  if (option.choices !== undefined && (!Array.isArray(option.choices) || !option.choices.every(isOptionChoice))) return false;
  return true;
}

function isAgentEvent(value: unknown): value is AgentEvent {
  if (!value || typeof value !== "object") return false;
  const event = value as Record<string, unknown>;
  switch (event.kind) {
    case "meta":
      return (event.model === undefined || isString(event.model)) &&
        (event.providerSessionId === undefined || isString(event.providerSessionId));
    case "options":
      return Array.isArray(event.options) && event.options.every(isSessionOption) &&
        (event.actions === undefined || isSessionActions(event.actions));
    case "commands": {
      if (event.trigger !== "/" && event.trigger !== "$" && event.trigger !== "@") return false;
      if (!Array.isArray(event.commands)) return false;
      return event.commands.every((command) => {
        if (!command || typeof command !== "object") return false;
        const item = command as Record<string, unknown>;
        return isString(item.name) &&
          (item.description === undefined || isString(item.description)) &&
          (item.source === undefined || isString(item.source));
      });
    }
    case "user": case "status": case "delta": case "assistant": case "thinking":
      return isString(event.text);
    case "tool-start":
      return isString(event.toolId) && isString(event.name) &&
        (event.detail === undefined || isString(event.detail));
    case "tool-end":
      return isString(event.toolId) &&
        (event.name === undefined || isString(event.name)) &&
        (event.detail === undefined || isString(event.detail)) &&
        (event.ok === undefined || isBoolean(event.ok));
    case "done":
      return event.stats === undefined || isString(event.stats);
    case "files-changed":
      return Array.isArray(event.files) && event.files.every((file) => {
        if (!file || typeof file !== "object") return false;
        const item = file as Record<string, unknown>;
        return isString(item.path) && typeof item.adds === "number" && Number.isFinite(item.adds) &&
          typeof item.dels === "number" && Number.isFinite(item.dels) && isString(item.status);
      });
    case "error":
      return isString(event.message);
    default:
      return false;
  }
}

function isSessionActions(value: unknown): boolean {
  if (!value || typeof value !== "object") return false;
  const actions = value as Record<string, unknown>;
  return actions.fork === undefined || isBoolean(actions.fork);
}
