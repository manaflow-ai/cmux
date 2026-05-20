import { callNative } from "./bridge";
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
};

export type Action =
  | { type: "context"; context: AppContext }
  | { type: "providers"; providers: ProviderInfo[] }
  | { type: "selectProvider"; providerId: ProviderId }
  | { type: "setInput"; input: string }
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
        id: crypto.randomUUID(),
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
      return { ...state, selectedProviderId: action.providerId };
    case "setInput":
      return { ...state, input: action.input };
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
    case "provider.started":
      return {
        ...state,
        runningSessionId: event.sessionId,
        status: "running",
        log: appendLog(state, "info", `${event.providerId} ${event.executablePath} ${event.arguments.join(" ")}`),
      };
    case "provider.output":
      return {
        ...state,
        log: appendLog(state, event.stream, event.text),
      };
    case "provider.exit":
      return {
        ...state,
        runningSessionId: undefined,
        status: event.status === 0 ? "idle" : "failed",
        log: appendLog(state, event.status === 0 ? "info" : "error", `${event.providerId} exited ${event.status}`),
      };
  }
}

function appendLog(state: SessionState, level: LogEntry["level"], text: string): LogEntry[] {
  const next = [
    ...state.log,
    {
      id: crypto.randomUUID(),
      level,
      text,
    },
  ];
  return next.slice(-300);
}

export function messageForError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
