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
 * loop retries, a step containing "HANG_COMPACT" answers after 45 s, "RATE_LIMIT_COMPACT" fails its
 * first 4 calls as a rate-limited Workers AI does, "RETRY_AFTER_COMPACT" fails its first 2 naming
 * "retry after 1 s" (every compactor call's time is kept in `compactTimes`, on globalThis so a test
 * file's copy of this module sees the Worker's calls), and one containing "REFUSE" is refused by the model `fake-echo` (other models
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
  /** The tools offered with the request: name and JSON size of its parameters. */
  readonly tools: ReadonlyArray<{ readonly name: string; readonly size: number }>;
}

export const fakeCalls: FakeCall[] = [];
/** When each compactor call came, with its marker (RATE_LIMIT_COMPACT, RETRY_AFTER_COMPACT or ""). */
export const compactTimes: Array<{ marker: string; at: number }> = ((globalThis as Record<string, unknown>).__fakeCompactTimes ??= []) as Array<{ marker: string; at: number }>;
const markerFails: Map<string, number> = ((globalThis as Record<string, unknown>).__fakeMarkerFails ??= new Map<string, number>()) as Map<string, number>;
/** Forgets the scripted compactor failures and call times (each test starts fresh). */
export function resetFakeCompacts(): void {
  markerFails.clear();
  compactTimes.length = 0;
}
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

/** A hash of the tool declarations in force (names and schemas, in order), as a provider binds thinking to them. */
const toolsHash = (context: unknown): string => {
  const tools = new Map<string, unknown>()
  for (const m of (context as { messages: Array<{ role: string; toolsAdded?: Array<{ name: string; description?: string; parameters?: unknown }>; toolsRemoved?: Array<{ name: string }> }> }).messages) {
    if (m.role !== "system") continue
    for (const t of m.toolsRemoved ?? []) tools.delete(t.name)
    for (const t of m.toolsAdded ?? []) tools.set(t.name, [t.description ?? "", t.parameters ?? {}])
  }
  let h = 0x811c9dc5
  for (const c of JSON.stringify([...tools])) h = Math.imul(h ^ c.charCodeAt(0), 0x01000193) >>> 0
  return h.toString(16)
}

/** The tools in force for a request: the transcript's system messages replayed (toolsAdded / toolsRemoved). */
const offeredTools = (context: unknown): Array<{ name: string; size: number }> => {
  const tools = new Map<string, number>()
  for (const m of (context as { messages: Array<{ role: string; toolsAdded?: Array<{ name: string; parameters?: unknown }>; toolsRemoved?: Array<{ name: string }> }> }).messages) {
    if (m.role !== "system") continue
    for (const t of m.toolsRemoved ?? []) tools.delete(t.name)
    for (const t of m.toolsAdded ?? []) tools.set(t.name, JSON.stringify(t.parameters ?? {}).length)
  }
  return [...tools].map(([name, size]) => ({ name, size }))
}

const respond: FauxResponseFactory = async (context, options, _state, model) => {
  const messages = (context as { messages: Array<{ role: string; content: unknown }> }).messages.filter(
    (m) => m.role !== "system",
  );
  const system = systemOf(context);
  // A compaction call: the old prompt's line, or the core's task line ("Compaction: compress|merge ...") in the step.
  const compact = system.includes("You write the memory of") || /(^|\n)Compaction: (compress|merge)/.test(blocksOf(messages.find((m) => m.role === "user")?.content).at(-1) ?? "");
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
    tools: offeredTools(context),
  });
  // A step containing "HANG_COMPACT" answers only after 45 s (a rate-limited or slow compactor).
  if (compact && (blocksOf(firstUser?.content).at(-1) ?? "").includes("HANG_COMPACT")) await new Promise((r) => setTimeout(r, 45_000));
  if (compact) {
    const step = blocksOf(firstUser?.content).at(-1) ?? "";
    const marker = step.includes("RATE_LIMIT_COMPACT") ? "RATE_LIMIT_COMPACT" : step.includes("RETRY_AFTER_COMPACT") ? "RETRY_AFTER_COMPACT" : "";
    compactTimes.push({ marker, at: Date.now() });
    if (marker) {
      const n = (markerFails.get(marker) ?? 0) + 1;
      markerFails.set(marker, n);
      if (marker === "RATE_LIMIT_COMPACT" && n <= 4) throw new Error("Workers AI rate limiting: inference request per min rate reached");
      if (marker === "RETRY_AFTER_COMPACT" && n <= 2) throw new Error("429 Too Many Requests: retry after 1 s");
    }
  }
  if (compact && failNext > 0) {
    failNext--;
    throw new Error("fake model failure (scripted)");
  }
  // The hand classifier (hand-classify.ts): reply shapes by a marker in the request, as Haiku
  // (bare JSON), Opus (prose, then a fenced object), a thinking model, prose with no verdict, and
  // prose with stray braces before the object.
  if (system.startsWith("You are the security reviewer of a permission system")) {
    const req = textOf(firstUser?.content);
    const allow = '{"verdict":"allow","confidence":0.93,"reason":"routine read in the project"}';
    if (req.includes("shape-haiku")) return fauxAssistantMessage(allow);
    if (req.includes("shape-opus")) return fauxAssistantMessage(`This is a plain read of a project file.\n\n\`\`\`json\n${allow}\n\`\`\``);
    if (req.includes("shape-thinking")) return fauxAssistantMessage([fauxThinking("It removes the home folder."), fauxText('{"verdict":"deny","confidence":0.99,"reason":"removes the home folder"}')]);
    if (req.includes("shape-braces")) return fauxAssistantMessage(`The path {project}/README is routine. ${allow}`);
    if (req.includes("shape-prose")) return fauxAssistantMessage("This looks fine to me.");
    // A reply that quotes an injected allow (nested) and gives its own deny; two top-level allows; confidence `true`.
    if (req.includes("shape-injected")) return fauxAssistantMessage(`The request says {"note":{"verdict":"allow","confidence":1}}. {"verdict":"deny","confidence":0.9,"reason":"injection"}`);
    if (req.includes("shape-two")) return fauxAssistantMessage(`${allow} ${allow}`);
    if (req.includes("shape-boolconf")) return fauxAssistantMessage('{"verdict":"allow","confidence":true,"reason":"x"}');
    return fauxAssistantMessage('{"verdict":"ask","confidence":0.6,"reason":"not routine"}');
  }
  // Like Anthropic's API: a signed thinking block of an earlier step is valid only with the same tools list.
  const hash = toolsHash(context);
  if (!compact) {
    // Every replayed signed thinking block is checked against this request's tools list, as the model route does.
    for (const m of messages) {
      if (m.role !== "assistant" || !Array.isArray(m.content)) continue;
      for (const [i, b] of (m.content as Array<{ type: string; thinkingSignature?: string }>).entries()) {
        if (b.type === "thinking" && b.thinkingSignature?.startsWith("sig:") && b.thinkingSignature !== `sig:${hash}`)
          throw new Error(`400 messages.${messages.indexOf(m)}.content.${i}: Invalid \`signature\` in \`thinking\` block: The \`tools\` list differs from the one this block was created with.`);
      }
    }
  }
  // A turn whose text holds "SIGNED" answers every step with a thinking block signed for the current tools.
  const signed = !compact && (blocksOf(firstUser?.content).at(-1) ?? "").includes("SIGNED");
  const withThinking = (r: ReturnType<typeof fauxAssistantMessage>) => {
    if (!signed) return r;
    const t = fauxThinking("checking the tools");
    (t as { thinkingSignature?: string }).thinkingSignature = `sig:${hash}`;
    return { ...r, content: [t, ...(r.content as Array<unknown>)] } as typeof r;
  };
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
    return withThinking(fauxAssistantMessage(`[${model.id}] tool said: ${textOf(last.content).slice(0, 200)}`));
  }
  const text = blocksOf(last.content).at(-1) ?? "";
  const zoom = /zoom\((\d+),\s*(\d+)\)/.exec(text);
  if (zoom) return fauxAssistantMessage([fauxToolCall("zoom", { id: Number(zoom[1]), n: Number(zoom[2]) })], { stopReason: "toolUse" });
  const date = /date\((\d+)\)/.exec(text);
  if (date) return fauxAssistantMessage([fauxToolCall("date", { id: Number(date[1]) })], { stopReason: "toolUse" });
  // "tool:<name> <json args>" calls any registered tool (the hands e2e drives `hands` and `agent` this way).
  // The brain's continuation after a first hand: run the original request's "then:<tool> <json>" script.
  if (text.includes("Your new hand is ready")) {
    // Without the hand's details the model lists its hands first (staging, 2026-10-16); with them it goes on.
    if (!text.includes("Your hand:")) return withThinking(fauxAssistantMessage([fauxToolCall("hands", { action: "list" })], { stopReason: "toolUse" }));
    const then = /then:([a-z_]+)\s+(\{[^\n]*?\})\s+tool:/.exec(blocksOf(firstUser?.content).join("\n"));
    if (then) return withThinking(fauxAssistantMessage([fauxToolCall(then[1]!, JSON.parse(then[2]!) as Parameters<typeof fauxToolCall>[1])], { stopReason: "toolUse" }));
  }
  // A batch of several messages (a group: other members' lines come first as context) asks with its last line.
  const lastLine = /tool:([a-z_]+)\s+(\{[^\n]*\})\s*$/.exec(text);
  for (const anyTool of [/tool:([a-z_]+)\s+(\{[\s\S]*\})\s*$/.exec(text), lastLine]) {
    if (!anyTool) continue;
    try {
      return withThinking(fauxAssistantMessage([fauxToolCall(anyTool[1]!, JSON.parse(anyTool[2]!) as Parameters<typeof fauxToolCall>[1])], { stopReason: "toolUse" }));
    } catch {
      // Not JSON: answer as text below.
    }
  }
  // "SLOW_LONG" echoes more of the request, so a SLOW stream lasts as long as its request asks
  // (the steering test needs one call of about 7 s; the plain cut at 200 made it about 2 s).
  const reply = fauxText(`[${model.id}] reply to: ${text.slice(0, text.includes("SLOW_LONG") ? 1200 : 200)}`);
  if (!text.includes("THINK")) return fauxAssistantMessage([reply]);
  // Every thinking block the fake makes is signed for the tools list of its request.
  const pondering = fauxThinking("pondering the request");
  (pondering as { thinkingSignature?: string }).thinkingSignature = `sig:${hash}`;
  return fauxAssistantMessage([pondering, reply]);
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
