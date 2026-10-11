import { expect, test } from "bun:test";
import {
  codexAdapter,
  codexSetSharedServerForTest,
} from "../adapters/codex";
import type { SessionCtx } from "../types";

type Sent = { method: string; params: unknown };
type TurnWaiter = {
  resolve: (id: string | null) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

test("Stop reports one timeout and clears its 30-second turn waiter", async () => {
  const sent: Sent[] = [];
  const errors: string[] = [];
  const state = {
    turnActive: true,
    currentTurnId: undefined as string | undefined,
    activeGeneration: 1,
    turnWaiters: [] as TurnWaiter[],
  };
  const sess = {
    id: "codex-stop-timeout",
    provider: "codex",
    cwd: "/tmp",
    title: "Codex stop timeout",
    autoApprove: true,
    startOptions: {},
    status: "running",
    events: [],
    internal: { threadId: "thread-timeout", codex: state },
    emit(evt: { kind: string; message?: string }) {
      if (evt.kind === "error" && evt.message) errors.push(evt.message);
    },
    setStatus() {},
  } as unknown as SessionCtx;

  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  const scheduled: { callback: () => void; delay: number }[] = [];
  globalThis.setTimeout = ((callback: TimerHandler, delay?: number) => {
    scheduled.push({
      callback: callback as () => void,
      delay: delay ?? 0,
    });
    return scheduled.length as unknown as ReturnType<typeof setTimeout>;
  }) as typeof setTimeout;
  globalThis.clearTimeout = (() => {}) as typeof clearTimeout;

  codexSetSharedServerForTest({
    request(method: string, params?: unknown) {
      sent.push({ method, params });
      return Promise.resolve({});
    },
    write() {},
    sessionsByThread: new Map(),
  });

  try {
    // Three presses, because the startup window shows the user nothing
    // happening for 30 seconds and Esc is cheap to hit again. They must share
    // one waiter, one timer and one report.
    codexAdapter.stop(sess);
    codexAdapter.stop(sess);
    codexAdapter.stop(sess);

    expect(scheduled).toHaveLength(1);
    expect(scheduled[0].delay).toBe(30_000);
    expect(state.turnWaiters).toHaveLength(1);
    expect(sent).toEqual([]);

    scheduled[0].callback();
    await Promise.resolve();
    await Promise.resolve();

    // The adapter builds this Error itself, so it reports the message rather
    // than stringifying the Error into a doubled "Error: Error: ...".
    expect(errors).toEqual(["Codex stop failed: codex turn did not start before the stop deadline"]);
    expect(sent).toEqual([]);
    expect(state.turnWaiters).toHaveLength(0);
  } finally {
    codexSetSharedServerForTest(null);
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  }
});
