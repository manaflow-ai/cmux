// Stop must send both protocol IDs: TurnInterruptParams in the codex
// app-server protocol carries a required threadId AND turnId, so an interrupt
// missing the turn ID is rejected and the turn keeps running. These cases drive
// codexAdapter.stop() and assert on the params that actually reach the server.
import {
  codexAdapter,
  codexInterruptParamsForTest,
  codexResolveTurnWaitersForTest,
  codexSetSharedServerForTest,
  codexStopGenerationMatchesForTest,
  codexStopWaitTimeoutsForTest,
  codexWaitForTurnIdForTest,
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
  turnWaiters: { resolve: (id: string | null) => void; reject: (err: Error) => void; timer: ReturnType<typeof setTimeout> }[];
  pendingStop?: Promise<void>;
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
// notification does, then lets stop()'s .then() callback run. This drives the
// production resolver so a regression inside it fails these cases.
async function deliverTurnId(state: CodexTestState, id: string | null) {
  state.currentTurnId = id ?? undefined;
  codexResolveTurnWaitersForTest(state, id);
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
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
  // Codex's turn/start request remains live for 30 seconds, so the waiter must
  // outlast the old five-second deadline. codex-stop-timeout.test.ts pins that
  // deadline with fake timers; sleeping past a real one here would pin no
  // value and cost CI five seconds on every run.
  if (state.turnWaiters.length !== 1 || state.turnWaiters[0].timer === undefined) {
    throw new Error(`Stop must park exactly one waiter with a deadline: ${state.turnWaiters.length}`);
  }
  await deliverTurnId(state, "turn-2");
  if (sent.length !== 1 || JSON.stringify(sent[0].params) !== JSON.stringify({ threadId: "thread-2", turnId: "turn-2" })) {
    throw new Error(`A late turn ID must produce one complete interrupt: ${JSON.stringify(sent)}`);
  }
}

// 2b. If the turn finishes before its startup notification, the pending Stop
// must settle without sending a stale interrupt or reporting a failure.
{
  const sent: Sent[] = [];
  codexSetSharedServerForTest(fakeServer(sent));
  const { sess, state, errors } = session("thread-2b", { currentTurnId: undefined });
  codexAdapter.stop(sess);
  state.turnActive = false;
  state.activeGeneration = undefined;
  await deliverTurnId(state, null);
  if (sent.length !== 0 || errors.length !== 0) {
    throw new Error(`A completed startup must settle Stop quietly: ${JSON.stringify({ sent, errors })}`);
  }
}

// 2c. Extra Stop presses inside the startup window must not fan out. Without
// the dedupe, three presses park three waiters and one late turn/started
// notification turns into three identical interrupts.
{
  const sent: Sent[] = [];
  codexSetSharedServerForTest(fakeServer(sent));
  const { sess, state, errors } = session("thread-2c", { currentTurnId: undefined });
  codexAdapter.stop(sess);
  codexAdapter.stop(sess);
  codexAdapter.stop(sess);
  if (state.turnWaiters.length !== 1) {
    throw new Error(`Repeated Stop must share one startup waiter: ${state.turnWaiters.length}`);
  }
  await deliverTurnId(state, "turn-2c");
  if (sent.length !== 1 || JSON.stringify(sent[0].params) !== JSON.stringify({ threadId: "thread-2c", turnId: "turn-2c" })) {
    throw new Error(`Repeated Stop must send one interrupt, not one per press: ${JSON.stringify(sent)}`);
  }
  if (errors.length !== 0) {
    throw new Error(`A successful stop must report nothing: ${JSON.stringify(errors)}`);
  }
  if (state.pendingStop !== undefined) {
    throw new Error("A settled stop must release the dedupe slot for the next turn");
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

// The waiter contract both callers depend on. send()'s steer path must get
// null so it can report "codex turn is still starting"; only stop() asks for a
// rejection, and it rejects with its own message so nothing renders a doubled
// "Error: Error: ...".
{
  const steerState: CodexTestState = { turnActive: true, turnWaiters: [] };
  const steer = await codexWaitForTurnIdForTest(steerState, 5);
  if (steer !== null) {
    throw new Error(`A steer wait must expire as null rather than reject: ${String(steer)}`);
  }
  if (steerState.turnWaiters.length !== 0) {
    throw new Error("An expired waiter must unpark itself");
  }

  const stopState: CodexTestState = { turnActive: true, turnWaiters: [] };
  let message = "";
  await codexWaitForTurnIdForTest(stopState, 5, codexStopWaitTimeoutsForTest.stopDeadlineError)
    .then(() => {
      message = "resolved";
    })
    .catch((err: unknown) => {
      message = err instanceof Error ? err.message : String(err);
    });
  if (message !== codexStopWaitTimeoutsForTest.stopDeadlineError) {
    throw new Error(`A stop wait must reject with its own bare message: ${message}`);
  }
  if (codexStopWaitTimeoutsForTest.steerMs >= codexStopWaitTimeoutsForTest.turnStartMs) {
    throw new Error("A steer must give up sooner than a stop, not share its deadline");
  }
}

console.log("codex stop assertions passed");

export {};
