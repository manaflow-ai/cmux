import { expect, test } from "bun:test";
import { makeClientId } from "./ids";
import { initialState, reduceSession, shouldAutoStartProvider } from "./sessionModel";
import type { AppContext, ProviderInfo } from "./types";

const theme = {
  isDark: true,
  pageBackground: "transparent",
  surfaceBackground: "rgba(0, 0, 0, 0.3)",
  surfaceElevatedBackground: "rgba(0, 0, 0, 0.4)",
  inputBackground: "rgba(0, 0, 0, 0.2)",
  border: "rgba(255, 255, 255, 0.1)",
  borderStrong: "rgba(255, 255, 255, 0.2)",
  text: "rgba(255, 255, 255, 1)",
  mutedText: "rgba(255, 255, 255, 0.6)",
  softText: "rgba(255, 255, 255, 0.8)",
  accent: "rgba(138, 180, 248, 1)",
  accentSoft: "rgba(138, 180, 248, 0.2)",
  danger: "rgba(255, 141, 126, 1)",
  shadow: "rgba(0, 0, 0, 0.2)",
};

const context: AppContext = {
  panelId: "panel-1",
  workspaceId: "workspace-1",
  renderer: "react",
  initialProviderId: "codex",
  copy: {
    start: "Start",
    stop: "Stop",
    send: "Send",
    promptPlaceholder: "Ask anything",
  },
  theme,
};

const providers: ProviderInfo[] = [
  {
    id: "codex",
    displayName: "Codex",
    executableName: "codex",
    transportKind: "stdio-jsonrpc",
    arguments: ["app-server", "--listen", "stdio://"],
    autoStart: true,
  },
  {
    id: "claude",
    displayName: "Claude Code",
    executableName: "claude",
    transportKind: "stdio-jsonl",
    arguments: ["-p"],
    autoStart: false,
  },
];

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

test("auto start is enabled for idle auto-start providers after context and providers load", () => {
  const stateWithContext = reduceSession(initialState("react"), { type: "context", context });
  const state = reduceSession(stateWithContext, { type: "providers", providers });

  expect(shouldAutoStartProvider(state)).toBe(true);
});

test("auto start is disabled after a provider has already been attempted", () => {
  const state = reduceSession(
    reduceSession(reduceSession(initialState("react"), { type: "context", context }), {
      type: "providers",
      providers,
    }),
    { type: "autoStartAttempted", providerId: "codex" },
  );

  expect(shouldAutoStartProvider(state)).toBe(false);
});

test("claude does not auto start", () => {
  const claudeContext = { ...context, initialProviderId: "claude" as const };
  const state = reduceSession(
    reduceSession(initialState("react"), { type: "context", context: claudeContext }),
    { type: "providers", providers },
  );

  expect(shouldAutoStartProvider(state)).toBe(false);
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
