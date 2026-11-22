import type { Api, AssistantMessage, Context, Message, Model, Models, ModelThinkingLevel, Usage } from "@earendil-works/pi-ai";
import { blockPieces, CACHE_BLOCKS_HEADER, marksHeader, type PrefixCache, prefixNames, viewWrite } from "./cache-prefix.ts";
import { finishLine, type Memory, RETRY_MS, sizeCheck } from "./memory.ts";

/**
 * The compactor (spec section 4): one model call per node, no tools, in the core's strict order.
 * The `<chat>` context goes first, in 4-line blocks as the turn view; its last whole block is marked
 * (the next node's context starts with it) and so is the longest prefix an earlier compaction wrote
 * (cache-prefix.ts: Bedrock reads only at a mark); a call whose prefix another call is still writing
 * waits for that call's first event. The step (ruler + the message or the two lines) goes last. The
 * size loop runs in the same conversation with the core's `sizeCheck`.
 */
export interface CallRecord {
  readonly kind: "turn" | "compact";
  readonly ref: string;
  readonly model: string;
  readonly latencyMs: number;
  readonly usage: Usage | undefined;
  readonly stop: string;
  readonly error?: string;
  /** Time spent waiting for a prefix another compaction was writing, before the first try. */
  readonly waitMs?: number;
}

export interface CompactorDeps {
  readonly memory: Memory;
  readonly models: Models;
  readonly model: Model<Api>;
  readonly thinking?: ModelThinkingLevel;
  readonly prompt: string;
  readonly agent: string;
  readonly record: (call: CallRecord) => void;
  /** The object's compaction prefixes (who writes which, which are live); none: no read marks, no waits. */
  readonly cache?: PrefixCache;
  /** Builds a node the main model refuses (a refusal repeats on every try, and rule 3 would block every turn). */
  readonly fallback?: { readonly model: Model<Api>; readonly thinking?: ModelThinkingLevel };
}

/** The model declined the step (Anthropic `stop_reason: refusal`, OpenAI refusal content). */
export class Refused extends Error {}

const textOf = (m: AssistantMessage) =>
  m.content
    .filter((p) => p.type === "text")
    .map((p) => (p as { text: string }).text)
    .join("");

/**
 * Builds one node; throws when the model fails or answers nothing, `Refused` when it declines.
 * A refusal is retried once on the fallback model, in a fresh conversation (the declined model's
 * blocks mean nothing to it), as the Rust host does.
 */
export async function buildNode(deps: CompactorDeps, l: number, i: number): Promise<string> {
  try {
    return await buildWith(deps, l, i);
  } catch (e) {
    if (!(e instanceof Refused) || !deps.fallback) throw e;
    const { fallback, ...rest } = deps;
    return await buildWith({ ...rest, model: fallback.model, ...(fallback.thinking ? { thinking: fallback.thinking } : {}) }, l, i).catch(
      (f: unknown) => {
        throw new Error(`${e.message}; the fallback model failed too: ${f instanceof Error ? f.message : String(f)}`);
      },
    );
  }
}

async function buildWith(deps: Omit<CompactorDeps, "fallback">, l: number, i: number): Promise<string> {
  const req = deps.memory.compactRequest(l, i, deps.prompt, deps.agent);
  const context = req.context ? blockPieces(req.context) : [];
  const names = prefixNames(`${deps.model.provider}/${deps.model.id}\n${req.system}`, context);
  const asked = Date.now();
  const lead = deps.cache
    ? await deps.cache.acquire(names, viewWrite(context))
    : { plan: { read: undefined, write: viewWrite(context), names }, begun: () => undefined, end: () => undefined };
  const headers = { ...(context.length > 0 ? { [CACHE_BLOCKS_HEADER]: marksHeader(lead.plan) } : {}) };
  try {
    return await sizeLoop(deps, req, context, headers, lead.begun, l, i, Date.now() - asked);
  } finally {
    // A call that never got an event (failed before the model answered) leaves no entry: forget it.
    lead.end();
  }
}

async function sizeLoop(deps: Omit<CompactorDeps, "fallback">, req: ReturnType<Memory["compactRequest"]>, context: string[], headers: Record<string, string>, begun: () => void, l: number, i: number, waitMs = 0): Promise<string> {
  const messages: Message[] = [
    {
      role: "user",
      content: [...context.map((text) => ({ type: "text" as const, text })), { type: "text" as const, text: req.step }],
      timestamp: Date.now(),
    },
  ];
  const tries: string[] = [];
  for (;;) {
    const ctx: Context = { systemPrompt: req.system, messages };
    const started = Date.now();
    let refusalEvent = false;
    const reply = await deps.models.completeSimple(deps.model, ctx, {
      ...(deps.thinking && deps.thinking !== "off" ? { reasoning: deps.thinking } : {}),
      // The model's whole output budget: thinking at medium effort must not crowd out the line.
      maxTokens: deps.model.maxTokens,
      ...(Object.keys(headers).length > 0 ? { headers } : {}),
      onProviderStreamEvent: (data: unknown) => {
        // The first event: the model read or wrote this prefix, so calls waiting on it may go.
        begun();
        const type = (data as { type?: unknown } | null)?.type;
        if (typeof type === "string" && type.startsWith("response.refusal.")) refusalEvent = true;
      },
    });
    const refused = reply.rawStopReason === "refusal" || refusalEvent;
    const failed = refused || reply.stopReason === "error" || reply.stopReason === "aborted";
    deps.record({
      kind: "compact",
      ref: `${l}:${i}#${tries.length + 1}`,
      model: `${deps.model.provider}/${deps.model.id}`,
      latencyMs: Date.now() - started,
      usage: reply.usage,
      stop: reply.stopReason,
      ...(tries.length === 0 && waitMs > 0 ? { waitMs } : {}),
      ...(failed ? { error: refused ? `refusal: ${reply.errorMessage ?? ""}` : (reply.errorMessage ?? "error") } : {}),
    });
    if (refused) throw new Refused(`${deps.model.provider}/${deps.model.id} refused: ${reply.errorMessage ?? "refusal"}`);
    if (failed) throw new Error(reply.errorMessage ?? `model ${reply.stopReason}`);
    begun();
    tries.push(textOf(reply));
    const check = JSON.parse(sizeCheck(JSON.stringify(tries), req.room)) as
      | { accept: string }
      | { retry: string }
      | { fail: true };
    if ("accept" in check) return req.cut ? finishLine(req.cut, check.accept) : check.accept;
    if ("fail" in check) throw new Error("compactor answered an empty line");
    // Keep the conversation: the model sees its own line and the cut-at-limit feedback.
    messages.push(reply, { role: "user", content: [{ type: "text", text: check.retry }], timestamp: Date.now() });
  }
}

export interface PumpHost {
  readonly memory: Memory;
  /** The compactor's current model and prompt, read when each node starts (config may change). */
  deps(): CompactorDeps;
  /** A node was stored and the view refit. */
  onBuilt(l: number, i: number): void;
  /** A node failed for the first time since it last succeeded (spec 4.1: report once per node). */
  onFirstFailure(l: number, i: number, error: string): void;
  /** A failed node waits RETRY; the host makes sure something wakes the object then (eviction). */
  onRetryWait(at: number): void | Promise<void>;
  /** Why compaction is off for this object (no model it may use), or undefined: then pump starts nothing and schedules nothing. */
  off?(): string | undefined;
  /**
   * Where the shared hold lives across restarts (the object's storage). Without it a restart starts
   * every node again at once: the 2026-10-28 staging drain, where a bad credential made each
   * restarted Chief call the model about once a second per node.
   */
  readonly hold?: CompactorHold;
  /** First retry delay in ms (default RETRY_BASE_MS); tests make it small. */
  readonly retryBaseMs?: number;
  /** Random number in [0, 1) for the jitter (default Math.random; tests inject one). */
  readonly random?: () => number;
}

/** The compactor's shared hold, as stored: no node starts before `until`; `streak` failures in a row so far. */
export interface CompactorHold {
  read(): { readonly until: number; readonly streak: number } | undefined;
  write(hold: { readonly until: number; readonly streak: number }): void;
}

/** The hold in a Chief object's `cb_config` (row `compactor_hold`, JSON), for `PumpHost.hold`. */
export const compactorHold = (sql: SqlStorage): CompactorHold => ({
  read: () => {
    const v = sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'compactor_hold'`).toArray()[0]?.value;
    if (!v) return undefined;
    try {
      const h = JSON.parse(v) as { until?: unknown; streak?: unknown };
      return typeof h.until === "number" && typeof h.streak === "number" ? { until: h.until, streak: h.streak } : undefined;
    } catch {
      return undefined;
    }
  },
  write: (h) => void sql.exec(`INSERT INTO cb_config (name, value) VALUES ('compactor_hold', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`, JSON.stringify(h)),
});

/** First retry delay and the cap of the exponential backoff (spec 4.1 retries forever; this spaces them). */
export const RETRY_BASE_MS = 2_000
export const RETRY_CAP_MS = 5 * 60_000
/** A failure the next try hits again (credential, account): the first wait and the cap of its backoff. */
export const AUTH_RETRY_BASE_MS = 60_000
export const AUTH_RETRY_CAP_MS = 30 * 60_000

/** The provider refused the caller, not the request: a bad or expired credential, or no access (HTTP 401/403). */
export const isAuthFailure = (msg: string): boolean =>
  /^\s*40[13]\b|\b(?:status|HTTP)\s*40[13]\b|security token|unauthori[sz]ed|forbidden|invalid (?:api[ -]?)?key|access ?denied|expired token/i.test(msg)

/** A Retry-After the error names (seconds, or "retry after N s"), in ms; undefined when it names none. */
export const retryAfterMs = (msg: string): number | undefined => {
  const m = /retry[- ]after[^0-9]{0,4}(\d+(?:\.\d+)?)\s*(ms|milliseconds?|min(?:utes?)?|s|sec|seconds?)?/i.exec(msg)
  if (!m) return undefined
  const n = Number(m[1])
  if (!Number.isFinite(n)) return undefined
  const unit = (m[2] ?? "s").toLowerCase()
  return unit.startsWith("min") ? n * 60_000 : unit === "ms" || unit.startsWith("milli") ? n : n * 1000
}

/**
 * The next wait of a failed node (try `n`, from 1): the error's Retry-After when it names one, else
 * exponential backoff with full jitter, uniform in [0, min(cap, base * 2^(n-1))], at least 100 ms.
 */
export const backoffMs = (n: number, msg: string, base: number, random: () => number): number => {
  const told = retryAfterMs(msg)
  if (told !== undefined) return Math.min(RETRY_CAP_MS, Math.max(100, told))
  return Math.max(100, Math.floor(random() * Math.min(RETRY_CAP_MS, base * 2 ** Math.min(n - 1, 20))))
}

/**
 * The whole compactor's wait after `n` failures in a row (any node). Same as `backoffMs`, but a
 * failure the next try hits again (`isAuthFailure`) waits AUTH_RETRY_BASE_MS doubling to
 * AUTH_RETRY_CAP_MS, at least half of it (no near-zero jitter: every node would fail the same way).
 */
export const sharedWaitMs = (n: number, msg: string, base: number, random: () => number): number => {
  if (retryAfterMs(msg) !== undefined || !isAuthFailure(msg)) return backoffMs(n, msg, base, random)
  const ceiling = Math.min(AUTH_RETRY_CAP_MS, AUTH_RETRY_BASE_MS * 2 ** Math.min(n - 1, 20))
  return Math.floor(ceiling / 2 + (random() * ceiling) / 2)
}

/**
 * The background compactor (spec 4.1). `pump()` starts every node the core says may start (rule 1
 * not built or running, rule 2 sources built, rule 3 everything before it summarized), up to JOBS
 * model calls; the host calls it after every append, and it calls itself after every node finishes.
 * A failed node is reported once, stays busy for its backoff (exponential with full jitter, capped
 * at 5 min, or the error's Retry-After), then is released and pumped again, forever. Every failure
 * also holds every new node until a shared wait ends (it grows with the failures in a row, and a
 * success resets it), so a fault all nodes share (a rate limit, a bad credential) costs one batch of
 * at most JOBS calls per wait, not one retry chain per node. A credential failure (401/403) waits
 * minutes (AUTH_RETRY_BASE_MS up to AUTH_RETRY_CAP_MS). The hold is kept in `host.hold`, so an
 * object restart does not start the nodes again before it ends.
 * `settle()` is spec 6: it resolves when every view line is a summary, checked again after every fit.
 */
export class Compactor {
  private readonly running = new Set<string>();
  private readonly failing = new Map<string, string>();
  private readonly waiters = new Set<() => void>();
  /** Tries per failing node (reset when it builds). */
  private readonly tries = new Map<string, number>();
  /** After a rate limit: no new node starts before this time. */
  private coolUntil = 0;
  private coolTimer: ReturnType<typeof setTimeout> | undefined;
  /** Failures in a row, for the whole compactor (a success resets it): the shared wait grows with it. */
  private rateTries = 0;

  constructor(private readonly host: PumpHost) {
    const kept = host.hold?.read();
    if (kept && Number.isFinite(kept.until) && Number.isFinite(kept.streak)) {
      this.coolUntil = kept.until;
      this.rateTries = Math.max(0, kept.streak);
    }
  }

  /** The wait before a cooled pump; 0 when not cooling. */
  cooling(now = Date.now()): number {
    return Math.max(0, this.coolUntil - now);
  }

  /** True when the host turned compaction off (pump starts nothing; a turn renders the view as it is). */
  off(): boolean {
    return this.host.off?.() !== undefined;
  }

  pump(): void {
    if (this.off()) return;
    const cool = this.cooling();
    if (cool > 0) {
      // A recent failure holds every node: take no new one until the wait ends (the core would mark it busy).
      if (this.coolTimer === undefined) {
        // The object may be evicted before the timer fires: the host wakes it when the hold ends.
        void this.host.onRetryWait(this.coolUntil);
        this.coolTimer = setTimeout(() => {
          this.coolTimer = undefined;
          this.pump();
        }, cool);
      }
      return;
    }
    let work: ReturnType<Memory["pump"]> = [];
    try {
      work = this.host.memory.pump();
      this.failing.delete("pump");
    } catch (e) {
      // A failed store read: nothing was started from it. Try again after RETRY.
      const msg = e instanceof Error ? e.message : String(e);
      if (!this.failing.has("pump")) {
        this.failing.set("pump", msg);
        this.host.onFirstFailure(-1, -1, `pump: ${msg}`);
      }
      void this.host.onRetryWait(Date.now() + RETRY_MS);
      setTimeout(() => this.pump(), RETRY_MS);
    }
    // The core marks returned nodes busy and caps model calls at JOBS (8) itself.
    for (const w of work) this.start(w.l, w.i);
    this.wake();
  }

  private start(l: number, i: number): void {
    const key = `${l}:${i}`;
    this.running.add(key);
    const generation = this.host.memory.generation
    Promise.resolve()
      .then(() => buildNode(this.host.deps(), l, i))
      .then((text) => this.host.memory.complete(l, i, text, generation))
      .then(
        () => {
          this.failing.delete(key);
          this.tries.delete(key);
          if (this.rateTries > 0 || this.coolUntil > 0) {
            this.rateTries = 0;
            this.coolUntil = 0;
            this.host.hold?.write({ until: 0, streak: 0 });
          }
          this.running.delete(key);
          this.host.onBuilt(l, i);
          this.pump();
        },
        (e: unknown) => {
          const msg = e instanceof Error ? e.message : String(e);
          if (!this.failing.has(key)) {
            this.failing.set(key, msg);
            this.host.onFirstFailure(l, i, msg);
          }
          const n = (this.tries.get(key) ?? 0) + 1;
          this.tries.set(key, n);
          const base = this.host.retryBaseMs ?? RETRY_BASE_MS;
          const random = this.host.random ?? Math.random;
          const wait = backoffMs(n, msg, base, random);
          // Every failure holds every node (see the class note): the nodes in flight still finish, none starts.
          this.rateTries++;
          const shared = sharedWaitMs(this.rateTries, msg, base, random);
          this.coolUntil = Math.max(this.coolUntil, Date.now() + Math.max(wait, shared));
          this.host.hold?.write({ until: this.coolUntil, streak: this.rateTries });
          void this.host.onRetryWait(Math.max(Date.now() + wait, this.coolUntil));
          // The node stays busy during the wait, as the spec's pump does.
          setTimeout(() => {
            this.running.delete(key);
            this.host.memory.fail(l, i);
            this.pump();
          }, wait);
          this.wake();
        },
      );
  }

  /** Spec 6: true once every view line is a summary; false if `signal` aborts first. */
  settle(signal?: AbortSignal): Promise<boolean> {
    return this.settleWhen(() => this.host.memory.settled(), signal);
  }

  /** The reference client's `Memory.settle(mem, from)`: true once every message before `end` is summarized (its view line built). */
  settleTo(end: number, signal?: AbortSignal): Promise<boolean> {
    return this.settleWhen(() => this.host.memory.first() >= end, signal);
  }

  private settleWhen(done: () => boolean, signal?: AbortSignal): Promise<boolean> {
    if (done()) return Promise.resolve(true);
    if (signal?.aborted) return Promise.resolve(false);
    return new Promise<boolean>((resolve) => {
      const finish = (value: boolean) => {
        this.waiters.delete(check);
        signal?.removeEventListener("abort", onAbort);
        resolve(value);
      };
      const check = () => {
        if (done()) finish(true);
      };
      const onAbort = () => finish(false);
      this.waiters.add(check);
      signal?.addEventListener("abort", onAbort, { once: true });
      this.pump();
    });
  }

  private wake(): void {
    for (const w of [...this.waiters]) w();
  }

  /** Model calls running or waiting out RETRY. */
  busy(): number {
    return this.running.size;
  }

  /** Nodes whose last attempt failed, with that first error. */
  failures(): Array<{ node: string; error: string }> {
    return [...this.failing].map(([node, error]) => ({ node, error }));
  }
}
