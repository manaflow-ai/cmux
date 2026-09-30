// Stop must send both protocol IDs: TurnInterruptParams in the codex
// app-server protocol carries a required threadId AND turnId, so an interrupt
// missing the turn ID is rejected and the turn keeps running. These cases drive
// codexAdapter.stop() and assert on the params that actually reach the server.
import {
  codexAdapter,
  codexInterruptParamsForTest,
  codexSetSharedServerForTest,
  codexStopGenerationMatchesForTest,
} from "../adapters/codex";
import type { SessionCtx } from "../types";

type Sent = { method: string; params: unknown };

function fakeServer(sent: Sent[]) {
  return {
    request(method: string, params?: unknown) {
      sent.push({ method, params });
      return Promise.resolve({});
    },
    write() {},
    sessionsByThread: new Map(),
  };
}

type CodexTestState = {
  turnActive: boolean;
  currentTurnId?: string;
  activeGeneration?: number;
  turnWaiters: ((id: string | null) => void)[];
};

function session(threadId: string | undefined, st: Partial<CodexTestState>): { sess: SessionCtx; state: CodexTestState; errors: string[] } {
  const state: CodexTestState = {
    turnActive: st.turnActive ?? true,
    currentTurnId: st.currentTurnId,
    activeGeneration: st.activeGeneration ?? 1,
    turnWaiters: [],
  };
  const errors: string[] = [];
  const sess = {
    id: "s1",
    provider: "codex",
    cwd: "/tmp",
    title: "t",
    autoApprove: true,
    startOptions: {},
    status: "running",
    events: [],
    internal: { threadId, codex: state },
    emit(evt: { kind: string; message?: string }) {
      if (evt.kind === "error" && evt.message) errors.push(evt.message);
    },
    setStatus() {},
  } as unknown as SessionCtx;
  return { sess, state, errors };
}

// Resolves whatever waitForTurnId() parked, the way a turn/started
// notification does, then lets stop()'s .then() callback run.
async function deliverTurnId(state: CodexTestState, id: string | null) {
  state.currentTurnId = id ?? undefined;
  for (const resolve of state.turnWaiters.splice(0)) resolve(id);
  await Promise.resolve();
  await Promise.resolve();
}

// 1. The turn ID is already known: interrupt goes out with both IDs. This is
// the case the old `request("turn/interrupt", { threadId })` got wrong.
{
  const sent: Sent[] = [];
  codexSetSharedServerForTest(fakeServer(sent));
  const { sess } = session("thread-1", { currentTurnId: "turn-1" });
  codexAdapter.stop(sess);
  if (sent.length !== 1 || sent[0].method !== "turn/interrupt") {
    throw new Error(`Stop must send exactly one turn/interrupt: ${JSON.stringify(sent)}`);
  }
  if (JSON.stringify(sent[0].params) !== JSON.stringify({ threadId: "thread-1", turnId: "turn-1" })) {
    throw new Error(`Interrupt must carry both protocol IDs: ${JSON.stringify(sent[0].params)}`);
  }
}

// 2. Stop pressed before turn/started arrived: nothing is sent until the turn
// ID is known, then the interrupt carries it.
{
  const sent: Sent[] = [];
  codexSetSharedServerForTest(fakeServer(sent));
  const { sess, state } = session("thread-2", { currentTurnId: undefined });
  codexAdapter.stop(sess);
  if (sent.length > 0) {
    throw new Error(`Stop must not interrupt before the turn ID is known: ${JSON.stringify(sent)}`);
  }
  await deliverTurnId(state, "turn-2");
  if (sent.length !== 1 || JSON.stringify(sent[0].params) !== JSON.stringify({ threadId: "thread-2", turnId: "turn-2" })) {
    throw new Error(`A late turn ID must produce one complete interrupt: ${JSON.stringify(sent)}`);
  }
}

// 3. A late turn ID must not interrupt a later generation on the same thread.
{
  const sent: Sent[] = [];
  codexSetSharedServerForTest(fakeServer(sent));
  const { sess, state } = session("thread-3", { currentTurnId: undefined, activeGeneration: 1 });
  codexAdapter.stop(sess);
  state.activeGeneration = 2;
  await deliverTurnId(state, "turn-3");
  if (sent.length > 0) {
    throw new Error(`Stop must not interrupt a newer generation: ${JSON.stringify(sent)}`);
  }
}

// 4. No thread, or no turn in flight: stop is a no-op.
{
  const sent: Sent[] = [];
  codexSetSharedServerForTest(fakeServer(sent));
  const missingThread = session(undefined, { currentTurnId: "turn-4" });
  codexAdapter.stop(missingThread.sess);
  const idle = session("thread-4", { currentTurnId: "turn-4", turnActive: false });
  codexAdapter.stop(idle.sess);
  if (sent.length > 0) {
    throw new Error(`Stop must send nothing without an active turn: ${JSON.stringify(sent)}`);
  }
}

// 5. A rejected interrupt surfaces as an error event instead of being dropped.
{
  const { sess, errors } = session("thread-5", { currentTurnId: "turn-5" });
  codexSetSharedServerForTest({
    request() {
      return Promise.reject(new Error("interrupt refused"));
    },
    write() {},
    sessionsByThread: new Map(),
  });
  codexAdapter.stop(sess);
  await Promise.resolve();
  await Promise.resolve();
  if (!errors.some((m) => m.includes("interrupt refused"))) {
    throw new Error(`A failed stop must be reported to the session: ${JSON.stringify(errors)}`);
  }
}

codexSetSharedServerForTest(null);

// The params helper itself: both IDs required, no partial request.
if (JSON.stringify(codexInterruptParamsForTest("thread-1", "turn-1")) !== JSON.stringify({ threadId: "thread-1", turnId: "turn-1" })) {
  throw new Error("Codex interrupt must include both protocol IDs");
}
if (codexInterruptParamsForTest("thread-1", undefined) !== null) {
  throw new Error("Stop must wait for a turn ID instead of sending an invalid interrupt request");
}
if (codexInterruptParamsForTest(undefined, "turn-1") !== null) {
  throw new Error("Stop must not interrupt without a thread ID");
}

if (!codexStopGenerationMatchesForTest({ turnActive: true, activeGeneration: 7 }, 7)) {
  throw new Error("Stop should interrupt the generation it observed");
}
if (codexStopGenerationMatchesForTest({ turnActive: false, activeGeneration: 7 }, 7)
    || codexStopGenerationMatchesForTest({ turnActive: true, activeGeneration: 8 }, 7)) {
  throw new Error("A late startup turn ID must not interrupt a completed or later generation");
}

console.log("codex stop assertions passed");

export {};
