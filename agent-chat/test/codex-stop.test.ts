import { codexInterruptParamsForTest, codexStopGenerationMatchesForTest } from "../adapters/codex";

const request = codexInterruptParamsForTest("thread-1", "turn-1");
if (JSON.stringify(request) !== JSON.stringify({ threadId: "thread-1", turnId: "turn-1" })) {
  throw new Error(`Codex interrupt must include both protocol IDs: ${JSON.stringify(request)}`);
}

if (codexInterruptParamsForTest("thread-1", undefined) !== null) {
  throw new Error("Stop must wait for a turn ID instead of sending an invalid interrupt request");
}
if (codexInterruptParamsForTest(undefined, "turn-1") !== null) {
  throw new Error("Stop must not interrupt without a thread ID");
}

console.log("codex stop assertions passed");

export {};

if (!codexStopGenerationMatchesForTest({ turnActive: true, activeGeneration: 7 }, 7)) {
  throw new Error("Stop should interrupt the generation it observed");
}
if (codexStopGenerationMatchesForTest({ turnActive: false, activeGeneration: 7 }, 7)
    || codexStopGenerationMatchesForTest({ turnActive: true, activeGeneration: 8 }, 7)) {
  throw new Error("A late startup turn ID must not interrupt a completed or later generation");
}
