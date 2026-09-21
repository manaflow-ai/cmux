Object.defineProperty(globalThis, "location", {
  configurable: true,
  value: { pathname: "/" },
});

const { composerDraftKey, consumeOptimisticUserEcho, foldEvent, latestRouting, restoreComposerDraft } = await import("../src/session");

const writes: Record<string, string> = {};
restoreComposerDraft({ setItem: (key: string, value: string) => { writes[key] = value; } }, "retry this exact prompt");

if (writes[composerDraftKey] !== "retry this exact prompt") {
  throw new Error(`pre-session start failure did not preserve composer draft: ${JSON.stringify(writes)}`);
}

const repeated = [
  { kind: "user" as const, text: "same" },
  { kind: "user" as const, text: "same" },
].reduce(foldEvent, []);
if (repeated.length !== 2) {
  throw new Error(`legitimate repeated user messages should be preserved, got ${JSON.stringify(repeated)}`);
}

const optimistic: string[] = ["same", "same"];
const queueLength = () => optimistic.length as number;
if (!consumeOptimisticUserEcho(optimistic, "same") || queueLength() !== 1) {
  throw new Error("first optimistic user echo was not consumed");
}
if (!consumeOptimisticUserEcho(optimistic, "same") || queueLength() !== 0) {
  throw new Error("second optimistic user echo was not consumed independently");
}
if (consumeOptimisticUserEcho(optimistic, "same")) {
  throw new Error("non-optimistic repeated user message should not be suppressed");
}

const startedRoute = foldEvent([], {
  kind: "routing",
  phase: "started",
  conversationId: "conversation-1",
  requestId: "request-1",
  attempt: 1,
});
if (startedRoute.length !== 0) {
  throw new Error("started routing metadata should not add transcript noise");
}
const handoffRoute = {
  kind: "routing" as const,
  phase: "handoff" as const,
  conversationId: "conversation-2",
  parentConversationId: "conversation-1",
  parentSessionId: "session-1",
  requestId: "request-2",
  attempt: 1,
};
if (latestRouting([handoffRoute, { kind: "delta", text: "next" }]) !== handoffRoute) {
  throw new Error("replayed history must recover the latest routing metadata through later transcript events");
}
if (latestRouting([{ kind: "delta", text: "legacy" }]) !== null) {
  throw new Error("legacy histories must have no routing metadata");
}

console.log("session store assertions passed");

export {};
