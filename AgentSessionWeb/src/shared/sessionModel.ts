import { callNative } from "./bridge";
import { makeClientId } from "./ids";
import { applyAgentTheme } from "./theme";
import type { AgentEvent, AppContext, ProviderId, ProviderInfo } from "./types";

export type LogEntry = {
  id: string;
  level: "info" | "stdout" | "stderr" | "error";
  text: string;
};

export type SessionState = {
  context?: AppContext;
  providers: ProviderInfo[];
  selectedProviderId: ProviderId;
  runningSessionId?: string;
  status: "loading" | "idle" | "starting" | "running" | "failed";
  input: string;
  log: LogEntry[];
  autoStartAttemptedProviderId?: ProviderId;
};

export type Action =
  | { type: "context"; context: AppContext }
  | { type: "providers"; providers: ProviderInfo[] }
  | { type: "selectProvider"; providerId: ProviderId }
  | { type: "setInput"; input: string }
  | { type: "autoStartAttempted"; providerId: ProviderId }
  | { type: "starting" }
  | { type: "failed"; message: string }
  | { type: "stopped" }
  | { type: "event"; event: AgentEvent }
  | { type: "sent"; text: string };

export function initialState(renderer: AppContext["renderer"]): SessionState {
  return {
    selectedProviderId: "codex",
    status: "loading",
    input: "",
    providers: [],
    log: [
      {
        id: makeClientId(),
        level: "info",
        text: `${renderer} ready`,
      },
    ],
  };
}

export function reduceSession(state: SessionState, action: Action): SessionState {
  switch (action.type) {
    case "context":
      return {
        ...state,
        context: action.context,
        selectedProviderId: action.context.initialProviderId,
        status: "idle",
      };
    case "providers":
      return { ...state, providers: action.providers };
    case "selectProvider":
      return {
        ...state,
        selectedProviderId: action.providerId,
        autoStartAttemptedProviderId:
          action.providerId === state.autoStartAttemptedProviderId ? state.autoStartAttemptedProviderId : undefined,
      };
    case "setInput":
      return { ...state, input: action.input };
    case "autoStartAttempted":
      return { ...state, autoStartAttemptedProviderId: action.providerId };
    case "starting":
      return { ...state, status: "starting", log: appendLog(state, "info", "starting") };
    case "failed":
      return { ...state, status: "failed", log: appendLog(state, "error", action.message) };
    case "stopped":
      return { ...state, status: "idle", runningSessionId: undefined, log: appendLog(state, "info", "stopped") };
    case "sent":
      return { ...state, input: "", log: appendLog(state, "info", `sent ${action.text.length} chars`) };
    case "event":
      return applyEvent(state, action.event);
  }
}

export async function loadInitialData(dispatch: (action: Action) => void): Promise<void> {
  try {
    const [context, providers] = await Promise.all([
      callNative<AppContext>("app.context"),
      callNative<ProviderInfo[]>("provider.list"),
    ]);
    applyAgentTheme(context.theme);
    dispatch({ type: "context", context });
    dispatch({ type: "providers", providers });
  } catch (error) {
    dispatch({ type: "failed", message: messageForError(error) });
  }
}

export async function startProvider(state: SessionState, dispatch: (action: Action) => void): Promise<void> {
  dispatch({ type: "starting" });
  try {
    await callNative("provider.start", {
      providerId: state.selectedProviderId,
      workingDirectory: state.context?.workingDirectory,
    });
  } catch (error) {
    dispatch({ type: "failed", message: messageForError(error) });
  }
}

export function shouldAutoStartProvider(state: SessionState): boolean {
  if (state.status !== "idle" || state.runningSessionId || !state.context) {
    return false;
  }
  if (state.autoStartAttemptedProviderId === state.selectedProviderId) {
    return false;
  }
  const provider = state.providers.find((item) => item.id === state.selectedProviderId);
  return provider?.autoStart === true;
}

export async function autoStartProvider(state: SessionState, dispatch: (action: Action) => void): Promise<void> {
  if (!shouldAutoStartProvider(state)) {
    return;
  }
  const providerId = state.selectedProviderId;
  dispatch({ type: "autoStartAttempted", providerId });
  dispatch({ type: "starting" });
  try {
    await callNative("provider.start", {
      providerId,
      workingDirectory: state.context?.workingDirectory,
    });
  } catch (error) {
    dispatch({ type: "failed", message: messageForError(error) });
  }
}

export async function sendInput(state: SessionState, dispatch: (action: Action) => void): Promise<void> {
  const text = state.input.trim();
  if (!text || !state.runningSessionId) {
    return;
  }
  try {
    await callNative("provider.writeLine", {
      sessionId: state.runningSessionId,
      text,
    });
    dispatch({ type: "sent", text });
  } catch (error) {
    dispatch({ type: "failed", message: messageForError(error) });
  }
}

export async function stopProvider(state: SessionState, dispatch: (action: Action) => void): Promise<void> {
  if (!state.runningSessionId) {
    return;
  }
  try {
    await callNative("provider.stop", {
      sessionId: state.runningSessionId,
    });
    dispatch({ type: "stopped" });
  } catch (error) {
    dispatch({ type: "failed", message: messageForError(error) });
  }
}

function applyEvent(state: SessionState, event: AgentEvent): SessionState {
  switch (event.type) {
    case "app.theme":
      if (!state.context) {
        return state;
      }
      return {
        ...state,
        context: {
          ...state.context,
          theme: event.theme,
        },
      };
    case "provider.started":
      return {
        ...state,
        runningSessionId: event.sessionId,
        status: "running",
        log: appendLog(state, "info", "provider started"),
      };
    case "provider.output":
      if (event.sessionId !== state.runningSessionId) {
        return state;
      }
      return {
        ...state,
        log: appendLog(state, event.stream, event.text),
      };
    case "provider.exit":
      if (event.sessionId !== state.runningSessionId) {
        return state;
      }
      return {
        ...state,
        runningSessionId: undefined,
        status: event.status === 0 ? "idle" : "failed",
        log: appendLog(state, event.status === 0 ? "info" : "error", `provider exited ${event.status}`),
      };
  }
}

function appendLog(state: SessionState, level: LogEntry["level"], text: string): LogEntry[] {
  const next = [
    ...state.log,
    {
      id: makeClientId(),
      level,
      text,
    },
  ];
  return next.slice(-300);
}

export function messageForError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
