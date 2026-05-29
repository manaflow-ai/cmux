import { callNative } from "./bridge";
import { makeClientId } from "./ids";
import { applyAgentTheme } from "./theme";
import type { AgentEvent, AgentSessionAttachment, AppContext, ProviderId, ProviderInfo } from "./types";

export type LogEntry = {
  id: string;
  level: "info" | "stdout" | "stderr" | "error";
  text: string;
};

export type TranscriptEntry = {
  id: string;
  role: "user" | "assistant" | "notice" | "activity";
  text: string;
  tone?: "error" | "warning";
  sessionId?: string;
  sentAtMs?: number;
  activityId?: string;
  activityKind?: "command" | "fileChange" | "other";
  activityStatus?: "inProgress" | "completed" | "failed" | "stopped";
  attachments?: AgentSessionAttachment[];
  detail?: string;
  output?: string;
};

export type SessionState = {
  context?: AppContext;
  providers: ProviderInfo[];
  selectedProviderId: ProviderId;
  runningSessionId?: string;
  status: "loading" | "idle" | "starting" | "running" | "stopping" | "failed";
  input: string;
  log: LogEntry[];
  transcript: TranscriptEntry[];
  autoStartAttemptedProviderIds: ProviderId[];
  seenSessionIds: string[];
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
  | { type: "sendFailed"; sessionId: string; message: string }
  | { type: "stopFailed"; sessionId: string; message: string }
  | { type: "stopped" }
  | { type: "event"; event: AgentEvent }
  | {
      type: "sent";
      attachments?: AgentSessionAttachment[];
      displayText?: string;
      sentAtMs?: number;
      sessionId: string;
      text: string;
      submittedInput: string;
    };

export function initialState(_renderer: AppContext["renderer"]): SessionState {
  return {
    selectedProviderId: "codex",
    status: "loading",
    input: "",
    providers: [],
    log: [],
    transcript: [],
    autoStartAttemptedProviderIds: [],
    seenSessionIds: [],
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
      if (!canSelectProvider(state)) {
        return state;
      }
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
        seenSessionIds: rememberSessionId(state, action.sessionId),
      };
    case "stopping":
      return {
        ...state,
        status: "stopping",
        requestedStopSessionId: action.sessionId,
        log: appendLog(state, "info", copyText(state, "stoppingStatus", "Stopping")),
      };
    case "failed":
      return {
        ...state,
        status: "failed",
        log: appendLog(state, "error", action.message),
        transcript: appendNoticeTranscript(state, action.message, "error"),
      };
    case "sendFailed":
      if (state.runningSessionId !== action.sessionId || state.requestedStopSessionId === action.sessionId) {
        return state;
      }
      return {
        ...state,
        status: "failed",
        log: appendLog(state, "error", action.message),
        transcript: appendNoticeTranscript(state, action.message, "error"),
      };
    case "stopFailed":
      if (state.runningSessionId !== action.sessionId && state.requestedStopSessionId !== action.sessionId) {
        return state;
      }
      return {
        ...state,
        requestedStopSessionId: undefined,
        status: "failed",
        log: appendLog(state, "error", action.message),
        transcript: appendNoticeTranscript(state, action.message, "error"),
      };
    case "stopped":
      return { ...state, status: "idle", runningSessionId: undefined, log: appendLog(state, "info", copyText(state, "stopped", "Stopped")) };
    case "sent":
      if (state.runningSessionId !== action.sessionId || state.requestedStopSessionId === action.sessionId) {
        return state;
      }
      return {
        ...state,
        input: state.input === action.submittedInput ? "" : state.input,
        log: appendLog(state, "info", formatCopy(state, "sentCharsFormat", "Sent %d chars", action.text.length)),
        transcript: appendUserTranscript(state, action.displayText ?? action.text, action.attachments, action.sentAtMs),
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
  await startProviderSnapshot(startProviderSnapshotFromState(state), dispatch);
}

type StartProviderSnapshot = {
  providerId: ProviderId;
  workingDirectory?: string;
  copy?: AppContext["copy"];
};

function startProviderSnapshotFromState(state: SessionState): StartProviderSnapshot {
  return {
    providerId: state.selectedProviderId,
    workingDirectory: state.context?.workingDirectory,
    copy: state.context?.copy,
  };
}

async function startProviderSnapshot(
  snapshot: StartProviderSnapshot,
  dispatch: (action: Action) => void,
): Promise<void> {
  dispatch({ type: "starting" });
  try {
    const reply = await callNative<{ sessionId: string }>("provider.start", {
      providerId: snapshot.providerId,
      workingDirectory: snapshot.workingDirectory,
    });
    dispatch({ type: "startAccepted", sessionId: reply.sessionId });
  } catch (error) {
    dispatch({ type: "failed", message: messageForError(error, snapshot.copy) });
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
  const snapshot = startProviderSnapshotFromState(state);
  dispatch({ type: "autoStartAttempted", providerId });
  await startProviderSnapshot(snapshot, dispatch);
}

export function selectProvider(providerId: ProviderId, state: SessionState, dispatch: (action: Action) => void): void {
  if (!canSelectProvider(state)) {
    return;
  }
  dispatch({ type: "selectProvider", providerId });
  void callNative("provider.select", { providerId }).catch(() => {});
}

export async function sendInput(
  state: SessionState,
  dispatch: (action: Action) => void,
  options: {
    attachments?: AgentSessionAttachment[];
    clearInput?: string;
    displayText?: string;
    text?: string;
  } = {},
): Promise<boolean> {
  const submittedInput = options.text ?? state.input;
  const clearInput = options.clearInput ?? submittedInput;
  if (submittedInput.length === 0 || !state.runningSessionId || state.status !== "running") {
    return false;
  }
  const sessionId = state.runningSessionId;
  try {
    await callNative("provider.writeLine", {
      sessionId,
      text: submittedInput,
    });
    dispatch({
      type: "sent",
      attachments: options.attachments,
      displayText: options.displayText,
      sentAtMs: Date.now(),
      sessionId,
      text: submittedInput,
      submittedInput: clearInput,
    });
    return true;
  } catch (error) {
    dispatch({ type: "sendFailed", sessionId, message: messageForError(error, state) });
    return false;
  }
}

export async function stopProvider(state: SessionState, dispatch: (action: Action) => void): Promise<void> {
  if (!state.runningSessionId || state.status === "stopping") {
    return;
  }
  const sessionId = state.runningSessionId;
  dispatch({ type: "stopping", sessionId });
  try {
    await callNative("provider.stop", {
      sessionId,
    });
  } catch (error) {
    dispatch({ type: "stopFailed", sessionId, message: messageForError(error, state) });
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

export function canSelectProvider(state: SessionState): boolean {
  return !state.runningSessionId && state.status !== "starting" && state.status !== "stopping";
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
    case "app.rateLimitRows":
      if (!state.context) {
        return state;
      }
      return {
        ...state,
        context: {
          ...state.context,
          rateLimitRows: event.rateLimitRows,
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
        seenSessionIds: rememberSessionId(state, event.sessionId),
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
        transcript: appendProviderTranscript(state, event),
      };
    case "provider.activity":
      if (event.sessionId !== state.runningSessionId) {
        return state;
      }
      return {
        ...state,
        transcript: appendProviderActivityTranscript(state, event),
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
          seenSessionIds: rememberSessionId(state, event.sessionId),
          status: "idle",
          log: appendLog(state, "info", copyText(state, "stopped", "Stopped")),
        };
      }
      return {
        ...state,
        runningSessionId: undefined,
        requestedStopSessionId: undefined,
        seenSessionIds: rememberSessionId(state, event.sessionId),
        status: event.status === 0 ? "idle" : "failed",
        log: appendLog(
          state,
          event.status === 0 ? "info" : "error",
          formatCopy(state, "providerExitedFormat", "Provider exited %d", event.status),
        ),
        transcript: event.status === 0
          ? state.transcript
          : appendNoticeTranscript(
              state,
              formatCopy(state, "providerExitedFormat", "Provider exited %d", event.status),
              "error",
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
  return (
    !state.seenSessionIds.includes(event.sessionId) &&
    state.status === "starting" &&
    !state.runningSessionId &&
    event.providerId === state.selectedProviderId
  );
}

function rememberSessionId(state: SessionState, sessionId: string): string[] {
  if (state.seenSessionIds.includes(sessionId)) {
    return state.seenSessionIds;
  }
  return [...state.seenSessionIds, sessionId].slice(-50);
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

function appendUserTranscript(
  state: SessionState,
  text: string,
  attachments?: AgentSessionAttachment[],
  sentAtMs?: number,
): TranscriptEntry[] {
  return appendTranscript(state.transcript, {
    attachments,
    id: makeClientId(),
    role: "user",
    sentAtMs,
    text,
  });
}

function appendProviderTranscript(
  state: SessionState,
  event: Extract<AgentEvent, { type: "provider.output" }>,
): TranscriptEntry[] {
  if (event.stream !== "stdout") {
    return appendNoticeTranscript(state, event.text, "warning");
  }

  const previous = state.transcript.at(-1);
  if (previous?.role === "assistant" && previous.sessionId === event.sessionId) {
    return [
      ...state.transcript.slice(0, -1),
      {
        ...previous,
        text: previous.text + event.text,
      },
    ];
  }

  return appendTranscript(state.transcript, {
    id: makeClientId(),
    role: "assistant",
    text: event.text,
    sessionId: event.sessionId,
  });
}

function appendProviderActivityTranscript(
  state: SessionState,
  event: Extract<AgentEvent, { type: "provider.activity" }>,
): TranscriptEntry[] {
  const existingIndex = lastActivityIndex(state.transcript, event.sessionId, event.activityId);
  if (existingIndex >= 0) {
    const previous = state.transcript[existingIndex];
    return [
      ...state.transcript.slice(0, existingIndex),
      {
        ...previous,
        text: event.action,
        detail: event.detail ?? previous.detail,
        activityKind: event.kind,
        activityStatus: event.status,
        output: (previous.output ?? "") + (event.outputDelta ?? ""),
      },
      ...state.transcript.slice(existingIndex + 1),
    ];
  }

  return appendTranscript(state.transcript, {
    id: makeClientId(),
    role: "activity",
    text: event.action,
    detail: event.detail,
    sessionId: event.sessionId,
    activityId: event.activityId,
    activityKind: event.kind,
    activityStatus: event.status,
    output: event.outputDelta,
  });
}

function lastActivityIndex(entries: TranscriptEntry[], sessionId: string, activityId: string): number {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry.role === "activity" && entry.sessionId === sessionId && entry.activityId === activityId) {
      return index;
    }
  }
  return -1;
}

function appendNoticeTranscript(
  state: SessionState,
  text: string,
  tone: NonNullable<TranscriptEntry["tone"]>,
): TranscriptEntry[] {
  return appendTranscript(state.transcript, {
    id: makeClientId(),
    role: "notice",
    tone,
    text,
  });
}

function appendTranscript(entries: TranscriptEntry[], entry: TranscriptEntry): TranscriptEntry[] {
  return [...entries, entry].slice(-200);
}

function copyText<K extends keyof AppContext["copy"]>(state: SessionState, key: K, fallback: string): string {
  return state.context?.copy[key] ?? fallback;
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

export function messageForError(error: unknown, stateOrCopy?: SessionState | AppContext["copy"]): string {
  const copy = copyForError(stateOrCopy);
  if (error instanceof Error && error.message) {
    if (copy && error.message === "Native bridge request failed.") {
      return copy.requestFailed;
    }
    return error.message;
  }
  return copy?.requestFailed ?? "Native bridge request failed.";
}

function copyForError(stateOrCopy?: SessionState | AppContext["copy"]): AppContext["copy"] | undefined {
  if (!stateOrCopy) {
    return undefined;
  }
  if ("requestFailed" in stateOrCopy) {
    return stateOrCopy;
  }
  return stateOrCopy.context?.copy;
}
