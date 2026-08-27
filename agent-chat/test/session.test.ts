Object.defineProperty(globalThis, "location", {
  configurable: true,
  value: { pathname: "/" },
});

const { composerDraftKey, consumeOptimisticUserEcho, foldEvent, restoreComposerDraft } = await import("../src/session");

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

console.log("session store assertions passed");

export {};
