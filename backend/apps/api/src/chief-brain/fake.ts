import {
  createFauxCore,
  fauxAssistantMessage,
  fauxText,
  fauxThinking,
  fauxToolCall,
  type FauxResponseFactory,
} from "@earendil-works/pi-ai/providers/faux";
import type { Api, Context, Model, ProviderStreams, TranscriptContext } from "@earendil-works/pi-ai";

/**
 * A deterministic model for tests and offline runs (`api: "fake"`). It never touches the network.
 * pi-ai's faux core streams the answer and estimates usage, including prompt-cache reads by
 * session id, so the cache accounting path runs too.
 *
 * Turn calls: "zoom(id, n)" or "date(id)" in the newest user text makes it call that tool (and
 * "tool:<name> {json}" calls any tool with those arguments), then
 * it answers with the tool result; anything else gets "[model] reply to: <text>". A text with
 * "THINK" also streams a thought first. Compactor calls (system starts "You write the memory of")
 * answer a one-line summary; a step containing "OVERSHOOT" first answers 600 bytes so the size
 * loop retries, and one containing "REFUSE" is refused by the model `fake-echo` (other models
 * answer it).
 *
 * `holdTurns()` makes every turn request wait until the returned release is called, so tests can
 * act while a turn is running (send a message, watch the compactor).
 */
export interface FakeCall {
  readonly model: string;
  readonly kind: "turn" | "compact";
  readonly system: string;
  readonly messages: number;
  /** Text blocks of the first user message, in order (the view pieces and the new message). */
  readonly firstUser: ReadonlyArray<string>;
  /** Text of every user message after the first (messages delivered mid-run), in order. */
  readonly laterUsers: ReadonlyArray<string>;
  readonly reasoning: string | undefined;
  readonly maxTokens: number | undefined;
}

export const fakeCalls: FakeCall[] = [];
let failNext = 0;

/** The next `n` fake compactor calls fail (to test compactor retries). */
export function failFakeCompacts(n: number): void {
  failNext = n;
}

let held: Promise<void> | undefined;
/** Turn requests wait until the returned function is called. */
export function holdTurns(): () => void {
  let release!: () => void;
  held = new Promise<void>((r) => (release = r));
  return () => {
    held = undefined;
    release();
  };
}

const textOf = (content: unknown): string =>
  typeof content === "string"
    ? content
    : Array.isArray(content)
      ? content
          .filter((p: { type?: string }) => p.type === "text")
          .map((p: { text?: string }) => p.text ?? "")
          .join("")
      : "";

const blocksOf = (content: unknown): string[] =>
  typeof content === "string"
    ? [content]
    : Array.isArray(content)
      ? content.filter((p: { type?: string }) => p.type === "text").map((p: { text?: string }) => p.text ?? "")
      : [];

function systemOf(context: TranscriptContext | Context): string {
  const c = context as { systemPrompt?: string; messages: Array<{ role: string; content: unknown }> };
  if (c.systemPrompt) return c.systemPrompt;
  return c.messages
    .filter((m) => m.role === "system")
    .map((m) => [textOf(m.content), ...Object.values((m as { sections?: Record<string, string | null> }).sections ?? {})].filter(Boolean).join("\n\n"))
    .join("\n");
}

const respond: FauxResponseFactory = async (context, options, _state, model) => {
  const messages = (context as { messages: Array<{ role: string; content: unknown }> }).messages.filter(
    (m) => m.role !== "system",
  );
  const system = systemOf(context);
  const compact = system.includes("You write the memory of");
  const firstUser = messages.find((m) => m.role === "user");
  fakeCalls.push({
    model: model.id,
    kind: compact ? "compact" : "turn",
    system,
    messages: messages.length,
    firstUser: blocksOf(firstUser?.content),
    laterUsers: messages.filter((m) => m.role === "user" && m !== firstUser).map((m) => textOf(m.content)),
    reasoning: (options as { reasoning?: string } | undefined)?.reasoning,
    maxTokens: options?.maxTokens,
  });
  if (compact && failNext > 0) {
    failNext--;
    throw new Error("fake model failure (scripted)");
  }
  const last = messages[messages.length - 1]!;
  if (!compact && held) {
    // A held request ends early when its run is aborted, as a real stream does.
    const signal = options?.signal;
    await Promise.race([
      held,
      new Promise<void>((resolve) => (signal?.aborted ? resolve() : signal?.addEventListener("abort", () => resolve(), { once: true }))),
    ]);
    if (signal?.aborted) throw new Error("Request was aborted");
  }
  if (compact) {
    const step = blocksOf(firstUser?.content).at(-1) ?? "";
    if (step.includes("REFUSE") && model.id === "fake-echo")
      return { ...fauxAssistantMessage([], { stopReason: "error", errorMessage: "The model refused to complete the request" }), rawStopReason: "refusal" };
    if (step.includes("OVERSHOOT") && last === firstUser) return fauxAssistantMessage("x".repeat(600));
    const body = step.split("\n").slice(3).join(" ").replace(/\s+/g, " ").trim();
    return fauxAssistantMessage(`sum: ${body.slice(0, 120)}`);
  }
  if (last.role === "toolResult") {
    return fauxAssistantMessage(`[${model.id}] tool said: ${textOf(last.content).slice(0, 200)}`);
  }
  const text = blocksOf(last.content).at(-1) ?? "";
  const zoom = /zoom\((\d+),\s*(\d+)\)/.exec(text);
  if (zoom) return fauxAssistantMessage([fauxToolCall("zoom", { id: Number(zoom[1]), n: Number(zoom[2]) })], { stopReason: "toolUse" });
  const date = /date\((\d+)\)/.exec(text);
  if (date) return fauxAssistantMessage([fauxToolCall("date", { id: Number(date[1]) })], { stopReason: "toolUse" });
  // "tool:<name> <json args>" calls any registered tool (the hands e2e drives `hands` and `agent` this way).
  const anyTool = /tool:([a-z_]+)\s+(\{[\s\S]*\})\s*$/.exec(text);
  if (anyTool) {
    try {
      return fauxAssistantMessage([fauxToolCall(anyTool[1]!, JSON.parse(anyTool[2]!) as Parameters<typeof fauxToolCall>[1])], { stopReason: "toolUse" });
    } catch {
      // Not JSON: answer as text below.
    }
  }
  const reply = fauxText(`[${model.id}] reply to: ${text.slice(0, 200)}`);
  return fauxAssistantMessage(text.includes("THINK") ? [fauxThinking("pondering the request"), reply] : [reply]);
};

let core: ReturnType<typeof createFauxCore> | undefined;
let slowCore: ReturnType<typeof createFauxCore> | undefined;

/** A turn whose newest user text holds "SLOW" streams in small tokens over a few seconds (live-frame tests). */
const isSlow = (context: TranscriptContext | Context): boolean => {
  const users = (context as { messages: Array<{ role: string; content: unknown }> }).messages.filter((m) => m.role === "user");
  return (blocksOf(users[users.length - 1]?.content).at(-1) ?? "").includes("SLOW");
};

export function fakeStreams(): ProviderStreams {
  core ??= createFauxCore({ api: "fake", provider: "fake", tokenSize: { min: 64, max: 64 } });
  slowCore ??= createFauxCore({ api: "fake", provider: "fake", tokenSize: { min: 3, max: 3 }, tokensPerSecond: 40 });
  const pick = (context: TranscriptContext | Context) => {
    const c = isSlow(context) ? slowCore! : core!;
    c.appendResponses([respond]);
    return c;
  };
  return {
    stream: (model: Model<Api>, context, options) => pick(context).stream(model, context, options),
    streamSimple: (model: Model<Api>, context, options) => pick(context).streamSimple(model, context, options),
  };
}
