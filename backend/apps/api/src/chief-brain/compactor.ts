import type { Api, AssistantMessage, Context, Message, Model, Models, ModelThinkingLevel, Usage } from "@earendil-works/pi-ai";
import { cutAtMarks, finishLine, type Memory, RETRY_MS, sizeCheck } from "./memory.ts";

/**
 * The compactor (spec section 4): one model call per node, no tools, in the core's strict order.
 * The `<chat>` context goes first, cut at the core's cache marks so consecutive calls read it from
 * the cache; the step (SCALE line + the message or the two lines) goes last. The size loop runs in
 * the same conversation with the core's `sizeCheck`.
 */
export interface CallRecord {
  readonly kind: "turn" | "compact";
  readonly ref: string;
  readonly model: string;
  readonly latencyMs: number;
  readonly usage: Usage | undefined;
  readonly stop: string;
  readonly error?: string;
}

export interface CompactorDeps {
  readonly memory: Memory;
  readonly models: Models;
  readonly model: Model<Api>;
  readonly thinking?: ModelThinkingLevel;
  readonly prompt: string;
  readonly agent: string;
  readonly record: (call: CallRecord) => void;
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
  const context = req.context ? cutAtMarks(req.context, req.marks) : [];
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
      onProviderStreamEvent: (data: unknown) => {
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
      ...(failed ? { error: refused ? `refusal: ${reply.errorMessage ?? ""}` : (reply.errorMessage ?? "error") } : {}),
    });
    if (refused) throw new Refused(`${deps.model.provider}/${deps.model.id} refused: ${reply.errorMessage ?? "refusal"}`);
    if (failed) throw new Error(reply.errorMessage ?? `model ${reply.stopReason}`);
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
}

/**
 * The background compactor (spec 4.1). `pump()` starts every node the core says may start (rule 1
 * not built or running, rule 2 sources built, rule 3 everything before it summarized), up to JOBS
 * model calls; the host calls it after every append, and it calls itself after every node finishes.
 * A failed node is reported once, stays busy for RETRY (10 s, no backoff), then is released and
 * pumped again, forever. `settle()` is spec 6: it resolves when every view line is a summary,
 * checked again after every fit.
 */
export class Compactor {
  private readonly running = new Set<string>();
  private readonly failing = new Map<string, string>();
  private readonly waiters = new Set<() => void>();

  constructor(private readonly host: PumpHost) {}

  pump(): void {
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
    Promise.resolve()
      .then(() => buildNode(this.host.deps(), l, i))
      .then((text) => this.host.memory.complete(l, i, text))
      .then(
        () => {
          this.failing.delete(key);
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
          void this.host.onRetryWait(Date.now() + RETRY_MS);
          // The node stays busy during the wait, as the spec's pump does.
          setTimeout(() => {
            this.running.delete(key);
            this.host.memory.fail(l, i);
            this.pump();
          }, RETRY_MS);
          this.wake();
        },
      );
  }

  /** Spec 6: true once every view line is a summary; false if `signal` aborts first. */
  settle(signal?: AbortSignal): Promise<boolean> {
    if (this.host.memory.settled()) return Promise.resolve(true);
    if (signal?.aborted) return Promise.resolve(false);
    return new Promise<boolean>((resolve) => {
      const done = (value: boolean) => {
        this.waiters.delete(check);
        signal?.removeEventListener("abort", onAbort);
        resolve(value);
      };
      const check = () => {
        if (this.host.memory.settled()) done(true);
      };
      const onAbort = () => done(false);
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
