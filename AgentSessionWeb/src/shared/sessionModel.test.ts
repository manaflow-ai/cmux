import { expect, test } from "bun:test";
import { makeClientId } from "./ids";
import { initialState, reduceSession } from "./sessionModel";

test("provider started event records running session", () => {
  const state = reduceSession(initialState("react"), {
    type: "event",
    event: {
      type: "provider.started",
      providerId: "codex",
      sessionId: "session-1",
      executablePath: "/usr/local/bin/codex",
      arguments: ["app-server", "--listen", "stdio://"],
    },
  });

  expect(state.status).toBe("running");
  expect(state.runningSessionId).toBe("session-1");
  expect(state.log.at(-1)?.text).toBe("provider started");
});

test("provider output is appended without changing running session", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "claude",
      sessionId: "session-1",
      stream: "stdout",
      text: "{\"type\":\"assistant\"}",
    },
  });

  expect(state.status).toBe("running");
  expect(state.runningSessionId).toBe("session-1");
  expect(state.log.at(-1)?.level).toBe("stdout");
});

test("provider output for a different session is ignored", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.output",
      providerId: "claude",
      sessionId: "session-x",
      stream: "stdout",
      text: "{\"type\":\"assistant\"}",
    },
  });

  expect(state).toBe(running);
});

test("provider exit for a different session is ignored", () => {
  const running = {
    ...initialState("solid"),
    status: "running" as const,
    runningSessionId: "session-1",
  };
  const state = reduceSession(running, {
    type: "event",
    event: {
      type: "provider.exit",
      providerId: "claude",
      sessionId: "session-x",
      status: 143,
    },
  });

  expect(state).toBe(running);
});

test("client ids do not require crypto.randomUUID", () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "crypto");
  Object.defineProperty(globalThis, "crypto", {
    configurable: true,
    value: {
      getRandomValues(bytes: Uint8Array) {
        bytes.fill(7);
        return bytes;
      },
    },
  });

  try {
    expect(makeClientId()).toMatch(/^[0-9a-f-]{36}$/);
    expect(initialState("react").log[0]?.id).toMatch(/^[0-9a-f-]{36}$/);
  } finally {
    if (descriptor) {
      Object.defineProperty(globalThis, "crypto", descriptor);
    } else {
      delete (globalThis as { crypto?: unknown }).crypto;
    }
  }
});
