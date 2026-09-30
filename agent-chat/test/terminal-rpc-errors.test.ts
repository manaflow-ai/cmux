import assert from "node:assert/strict";
import { focusTranscriptTerminal, setTranscriptRpcForTest, transcriptAdapter, transcriptRpcErrorEvent } from "../adapters/transcript";
import { foldEvent } from "../src/session";
import { AGENT_CHAT_LOCALES, agentChatCopyForLocale } from "../src/i18n";
import type { AgentEvent, SessionCtx } from "../types";

const navigatorDescriptor = Object.getOwnPropertyDescriptor(globalThis, "navigator");
const events: AgentEvent[] = [];
const calls: string[] = [];
const timeout = { ok: false, error: "ETIMEDOUT", errorCode: "timeout" as const };
const sess = {
  internal: { transcriptTarget: { agentSessionId: "fixture-agent", surfaceId: "fixture-surface" } },
  emit(event: AgentEvent) { events.push(event); },
} as unknown as SessionCtx;
setTranscriptRpcForTest(async (method) => { calls.push(method); return timeout; });
try {
  await transcriptAdapter.send(sess, "keep this prompt for recovery");
  transcriptAdapter.stop(sess);
  await Promise.resolve();
  const focusResult = await focusTranscriptTerminal(sess);
  assert.equal(focusResult.ok, false);
  assert.deepEqual(calls, ["mobile.chat.send", "mobile.chat.interrupt", "surface.focus"]);
  assert.equal(events.length, 3);
  assert.equal((events[0] as Extract<AgentEvent, { kind: "error" }>).prompt, "keep this prompt for recovery");
  for (const event of events) {
    assert.equal(event.kind, "error");
    assert.equal((event as Extract<AgentEvent, { kind: "error" }>).code, "terminal-rpc-timeout");
    for (const locale of AGENT_CHAT_LOCALES) {
      Object.defineProperty(globalThis, "navigator", { configurable: true, value: { languages: [locale] } });
      const blocks = foldEvent([], event);
      assert.deepEqual(blocks, [{ kind: "error", text: agentChatCopyForLocale(locale).terminalRequestTimeout }]);
      assert.ok(!JSON.stringify(blocks).includes("ETIMEDOUT"));
    }
  }
  assert.deepEqual(foldEvent([], { kind: "error", message: "legacy provider diagnostic" }), [{ kind: "error", text: "legacy provider diagnostic" }]);
  assert.deepEqual(transcriptRpcErrorEvent({ ok: false, error: "ordinary failure" }, "ordinary diagnostic"), { kind: "error", message: "ordinary diagnostic" });
  console.log("Send, interrupt, and focus timeout errors preserve prompt recovery and display localized copy in all 20 locales: OK");
} finally {
  setTranscriptRpcForTest(null);
  if (navigatorDescriptor) Object.defineProperty(globalThis, "navigator", navigatorDescriptor);
  else delete (globalThis as any).navigator;
}
