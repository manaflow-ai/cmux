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
  status: "loading" | "idle" | "starting" | "running" | "stopping" | "failed";
  input: string;
  log: LogEntry[];
  autoStartAttemptedProviderIds: ProviderId[];
  requestedStopSessionId?: string;
};

export type Action =
  | { type: "context"; context: AppContext }
  | { type: "providers"; providers: ProviderInfo[] }
  | { type: "selectProvider"; providerId: ProviderId }
  | { type: "setInput"; input: string }
  | { type: "autoStartAttempted"; providerId: ProviderId }
  | { type: "starting" }
  | { type: "startAccepted"; sessionId: string }
  | { type: "stopping"; sessionId: string }
  | { type: "failed"; message: string }
  | { type: "stopped" }
  | { type: "event"; event: AgentEvent }
  | { type: "sent"; text: string; submittedInput: string };

export function initialState(_renderer: AppContext["renderer"]): SessionState {
  return {
    selectedProviderId: "codex",
    status: "loading",
    input: "",
    providers: [],
    log: [],
    autoStartAttemptedProviderIds: [],
  };
}

export function reduceSession(state: SessionState, action: Action): SessionState {
  switch (action.type) {
    case "context":
      return appendContextReadyLog({
        ...state,
        context: action.context,
        selectedProviderId: action.context.initialProviderId,
        status: "idle",
      });
    case "providers":
      return { ...state, providers: action.providers };
    case "selectProvider":
      return {
        ...state,
        selectedProviderId: action.providerId,
      };
    case "setInput":
      return { ...state, input: action.input };
    case "autoStartAttempted":
      if (state.autoStartAttemptedProviderIds.includes(action.providerId)) {
        return state;
      }
      return {
        ...state,
        autoStartAttemptedProviderIds: [...state.autoStartAttemptedProviderIds, action.providerId],
      };
    case "starting":
      return { ...state, status: "starting", log: appendLog(state, "info", copyText(state, "startingStatus", "Starting")) };
    case "startAccepted":
      if (state.status !== "starting" || state.runningSessionId) {
        return state;
      }
      return {
        ...state,
        runningSessionId: action.sessionId,
        requestedStopSessionId: undefined,
      };
    case "stopping":
      return {
        ...state,
        status: "stopping",
        requestedStopSessionId: action.sessionId,
        log: appendLog(state, "info", copyText(state, "stoppingStatus", "Stopping")),
      };
    case "failed":
      return { ...state, status: "failed", log: appendLog(state, "error", action.message) };
    case "stopped":
      return { ...state, status: "idle", runningSessionId: undefined, log: appendLog(state, "info", copyText(state, "stopped", "Stopped")) };
    case "sent":
      return {
        ...state,
        input: state.input === action.submittedInput ? "" : state.input,
        log: appendLog(state, "info", formatCopy(state, "sentCharsFormat", "Sent %d chars", action.text.length)),
      };
    case "event":
      return applyEvent(state, action.event);
    default:
      return state;
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
  if (!canStartProvider(state)) {
    return;
  }
  dispatch({ type: "starting" });
  try {
    const reply = await callNative<{ sessionId: string }>("provider.start", {
      providerId: state.selectedProviderId,
      workingDirectory: state.context?.workingDirectory,
    });
    dispatch({ type: "startAccepted", sessionId: reply.sessionId });
  } catch (error) {
    dispatch({ type: "failed", message: messageForError(error, state) });
  }
}

export function shouldAutoStartProvider(state: SessionState): boolean {
  if (!canStartProvider(state)) {
    return false;
  }
  if (state.autoStartAttemptedProviderIds.includes(state.selectedProviderId)) {
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
  await startProvider(state, dispatch);
}

export function selectProvider(providerId: ProviderId, dispatch: (action: Action) => void): void {
  dispatch({ type: "selectProvider", providerId });
  void callNative("provider.select", { providerId }).catch(() => {});
}

export async function sendInput(state: SessionState, dispatch: (action: Action) => void): Promise<void> {
  const submittedInput = state.input;
  if (submittedInput.length === 0 || !state.runningSessionId) {
    return;
  }
  try {
    await callNative("provider.writeLine", {
      sessionId: state.runningSessionId,
      text: submittedInput,
    });
    dispatch({ type: "sent", text: submittedInput, submittedInput });
  } catch (error) {
    dispatch({ type: "failed", message: messageForError(error, state) });
  }
}

export async function stopProvider(state: SessionState, dispatch: (action: Action) => void): Promise<void> {
  if (!state.runningSessionId || state.status === "stopping") {
    return;
  }
  dispatch({ type: "stopping", sessionId: state.runningSessionId });
  try {
    await callNative("provider.stop", {
      sessionId: state.runningSessionId,
    });
  } catch (error) {
    dispatch({ type: "failed", message: messageForError(error, state) });
  }
}

export function statusLabel(state: SessionState): string {
  switch (state.status) {
    case "loading":
      return copyText(state, "loadingStatus", "Loading");
    case "idle":
      return copyText(state, "idleStatus", "Idle");
    case "starting":
      return copyText(state, "startingStatus", "Starting");
    case "running":
      return copyText(state, "runningStatus", "Running");
    case "stopping":
      return copyText(state, "stoppingStatus", "Stopping");
    case "failed":
      return copyText(state, "failedStatus", "Failed");
  }
}

export function canStartProvider(state: SessionState): boolean {
  return (state.status === "idle" || state.status === "failed") && !state.runningSessionId && Boolean(state.context);
}

export function canStopProvider(state: SessionState): boolean {
  return Boolean(state.runningSessionId) && state.status !== "stopping";
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
      if (event.sessionId === state.requestedStopSessionId) {
        return state;
      }
      if (state.runningSessionId && event.sessionId !== state.runningSessionId) {
        return state;
      }
      if (!state.runningSessionId && state.status !== "starting") {
        return state;
      }
      if (!state.runningSessionId && event.providerId !== state.selectedProviderId) {
        return state;
      }
      return {
        ...state,
        runningSessionId: event.sessionId,
        requestedStopSessionId: undefined,
        status: "running",
        log: appendLog(state, "info", copyText(state, "providerStarted", "Provider started")),
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
      if (!isCurrentOrPendingStartExit(state, event)) {
        return state;
      }
      if (event.sessionId === state.requestedStopSessionId) {
        return {
          ...state,
          runningSessionId: undefined,
          requestedStopSessionId: undefined,
          status: "idle",
          log: appendLog(state, "info", copyText(state, "stopped", "Stopped")),
        };
      }
      return {
        ...state,
        runningSessionId: undefined,
        requestedStopSessionId: undefined,
        status: event.status === 0 ? "idle" : "failed",
        log: appendLog(
          state,
          event.status === 0 ? "info" : "error",
          formatCopy(state, "providerExitedFormat", "Provider exited %d", event.status),
        ),
      };
    default:
      return state;
  }
}

function isCurrentOrPendingStartExit(state: SessionState, event: Extract<AgentEvent, { type: "provider.exit" }>): boolean {
  if (event.sessionId === state.runningSessionId) {
    return true;
  }
  return state.status === "starting" && !state.runningSessionId && event.providerId === state.selectedProviderId;
}

function appendContextReadyLog(state: SessionState): SessionState {
  const renderer = state.context?.renderer === "solid" ? "Solid" : "React";
  return {
    ...state,
    log: appendLog(state, "info", formatCopy(state, "rendererReadyFormat", "%@ ready", renderer)),
  };
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

function copyText<K extends keyof AppContext["copy"]>(state: SessionState, key: K, fallback: string): string {
  return state.context?.copy[key] || fallback;
}

function formatCopy<K extends keyof AppContext["copy"]>(
  state: SessionState,
  key: K,
  fallback: string,
  ...values: Array<string | number>
): string {
  return formatTemplate(copyText(state, key, fallback), values);
}

export function formatTemplate(template: string, values: Array<string | number>): string {
  let index = 0;
  return template.replace(/%(\d+\$)?[@d]/g, (_match, position: string | undefined) => {
    const valueIndex = position ? Number(position.slice(0, -1)) - 1 : index++;
    return String(values[valueIndex] ?? "");
  });
}

export function messageForError(error: unknown, state?: SessionState): string {
  if (error instanceof Error && error.message) {
    if (state && error.message === "Native bridge request failed.") {
      return copyText(state, "requestFailed", "Native bridge request failed.");
    }
    return error.message;
  }
  return state ? copyText(state, "requestFailed", "Native bridge request failed.") : "Native bridge request failed.";
}
