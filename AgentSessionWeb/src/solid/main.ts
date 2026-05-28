import { createEffect, createMemo, createSignal, onCleanup } from "solid-js";
import { render } from "solid-js/web";
import { subscribeToAgentEvents } from "../shared/bridge";
import { insertComposerToken } from "../shared/composerTokens";
import { isComposingEnter } from "../shared/keyboard";
import { codexModelLabel, providerBadgeLabel } from "../shared/providerDisplay";
import {
  initialState,
  autoStartProvider,
  canSelectProvider,
  canStartProvider,
  canStopProvider,
  loadInitialData,
  reduceSession,
  sendInput,
  selectProvider,
  startProvider,
  statusLabel,
  stopProvider,
  type Action,
  type SessionState,
  type TranscriptEntry,
} from "../shared/sessionModel";
import type { AgentSessionRateLimitRow, ProviderId } from "../shared/types";

function App() {
  const [state, setState] = createSignal<SessionState>(initialState("solid"));
  const dispatch = (action: Action) => setState((current) => reduceSession(current, action));

  void loadInitialData(dispatch);
  const unsubscribe = subscribeToAgentEvents((event) => dispatch({ type: "event", event }));
  onCleanup(unsubscribe);

  createEffect(() => {
    document.documentElement.dataset.status = state().status;
  });
  const autoStartState = createMemo(() => pickAutoStartState(state()), pickAutoStartState(state()), {
    equals: autoStartStateEquals,
  });
  createEffect(() => {
    void autoStartProvider(autoStartState(), dispatch);
  });

  return SessionSurface({ state, dispatch, renderer: "Solid" });
}

function pickAutoStartState(state: SessionState): SessionState {
  return {
    context: state.context,
    providers: state.providers,
    selectedProviderId: state.selectedProviderId,
    runningSessionId: state.runningSessionId,
    status: state.status,
    input: "",
    log: [],
    transcript: [],
    autoStartAttemptedProviderIds: state.autoStartAttemptedProviderIds,
    seenSessionIds: state.seenSessionIds,
    requestedStopSessionId: state.requestedStopSessionId,
  };
}

function autoStartStateEquals(previous: SessionState, next: SessionState): boolean {
  return (
    previous.context === next.context &&
    previous.providers === next.providers &&
    previous.selectedProviderId === next.selectedProviderId &&
    previous.runningSessionId === next.runningSessionId &&
    previous.status === next.status &&
    previous.autoStartAttemptedProviderIds === next.autoStartAttemptedProviderIds &&
    previous.seenSessionIds === next.seenSessionIds &&
    previous.requestedStopSessionId === next.requestedStopSessionId
  );
}

function SessionSurface({
  state,
  dispatch,
  renderer,
}: {
  state: () => SessionState;
  dispatch: (action: Action) => void;
  renderer: string;
}) {
  const provider = () => state().providers.find((item) => item.id === state().selectedProviderId);
  const canStart = () => canStartProvider(state());
  const canStop = () => canStopProvider(state());
  const canSend = () => state().status === "running" && state().input.length > 0;
  const root = document.createElement("section");
  root.className = "agent-shell";

  const thread = document.createElement("div");
  thread.className = "agent-thread";
  root.append(thread);
  const transcriptRows = new Map<string, HTMLDivElement>();
  createEffect(() => {
    const entries = state().transcript;
    thread.toggleAttribute("data-empty", entries.length === 0);
    const liveIds = new Set(entries.map((entry) => entry.id));
    for (const [id, row] of transcriptRows) {
      if (!liveIds.has(id)) {
        row.remove();
        transcriptRows.delete(id);
      }
    }
    entries.forEach((entry, index) => {
      let row = transcriptRows.get(entry.id);
      if (!row) {
        row = transcriptTurnElement(entry);
        transcriptRows.set(entry.id, row);
      }
      updateTranscriptTurn(row, entry);
      const current = thread.children.item(index);
      if (current !== row) {
        thread.insertBefore(row, current);
      }
    });
    while (thread.children.length > entries.length) {
      thread.lastElementChild?.remove();
    }
  });

  const composerStack = document.createElement("div");
  composerStack.className = "composer-stack";
  root.append(composerStack);

  const form = document.createElement("form");
  form.className = "composer";
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    void sendInput(state(), dispatch);
  });
  composerStack.append(form);

  const composerFrame = document.createElement("div");
  composerFrame.className = "composer-frame";
  form.append(composerFrame);

  const composerSurface = document.createElement("div");
  composerSurface.className = "composer-surface";
  composerFrame.append(composerSurface);

  const composerBody = document.createElement("div");
  composerBody.className = "composer-body";
  composerSurface.append(composerBody);

  const textarea = document.createElement("textarea");
  textarea.className = "prompt-input";
  textarea.addEventListener("input", () => dispatch({ type: "setInput", input: textarea.value }));
  textarea.addEventListener("keydown", (event) => {
    if (isComposingEnter(event)) {
      return;
    }
    if (event.key !== "Enter") {
      return;
    }
    if (event.shiftKey || event.altKey) {
      return;
    }
    event.preventDefault();
    void sendInput(state(), dispatch);
  });
  composerBody.append(textarea);
  const insertToken = (token: "@" | "$") => {
    const insertion = insertComposerToken({
      text: state().input,
      selectionStart: textarea.selectionStart ?? state().input.length,
      selectionEnd: textarea.selectionEnd ?? state().input.length,
      token,
    });
    dispatch({ type: "setInput", input: insertion.text });
    queueMicrotask(() => {
      textarea.focus();
      textarea.setSelectionRange(insertion.cursor, insertion.cursor);
    });
  };
  createEffect(() => {
    textarea.placeholder = state().context?.copy.promptPlaceholder ?? "";
    textarea.setAttribute("aria-label", state().context?.copy.promptPlaceholder ?? "");
    if (textarea.value !== state().input) {
      textarea.value = state().input;
    }
  });

  const composerFooter = document.createElement("div");
  composerFooter.className = "composer-footer";
  composerSurface.append(composerFooter);

  const leftRail = document.createElement("div");
  leftRail.className = "codex-left-rail";
  composerFooter.append(leftRail);

  const modelPicker = document.createElement("label");
  modelPicker.className = "model-picker";
  const modelIcon = document.createElement("span");
  modelIcon.className = "model-icon";
  modelIcon.setAttribute("aria-hidden", "true");
  const modelLabel = document.createElement("span");
  modelLabel.className = "model-label";
  const modelChevron = document.createElement("span");
  modelChevron.className = "model-chevron";
  modelChevron.setAttribute("aria-hidden", "true");
  modelChevron.textContent = "⌄";
  modelPicker.append(modelIcon, modelLabel, modelChevron);
  leftRail.append(modelPicker);

  const select = document.createElement("select");
  select.className = "provider-select";
  select.addEventListener("change", () => {
    selectProvider(select.value as ProviderId, state(), dispatch);
  });
  modelPicker.append(select);

  const composerSeparator = document.createElement("span");
  composerSeparator.className = "composer-separator";
  composerSeparator.setAttribute("aria-hidden", "true");
  leftRail.append(
    composerSeparator,
    codexIconButton("plus", "+"),
    codexIconButton("mention", "@", () => insertToken("@")),
    codexIconButton("skill", "$", () => insertToken("$")),
  );

  createEffect(() => {
    select.replaceChildren();
    for (const item of state().providers) {
      const option = document.createElement("option");
      option.value = item.id;
      option.textContent = item.displayName;
      select.append(option);
    }
    select.value = state().selectedProviderId;
    select.disabled = !canSelectProvider(state());
    select.setAttribute("aria-label", state().context?.copy.provider ?? "");
    modelIcon.textContent = provider() ? providerBadgeLabel(provider()!) : "C";
    modelLabel.textContent = codexModelLabel(provider());
  });

  const controlsRight = document.createElement("div");
  controlsRight.className = "codex-right-rail";
  composerFooter.append(controlsRight);

  const start = document.createElement("button");
  start.className = "codex-action codex-start";
  start.type = "button";
  start.addEventListener("click", () => void startProvider(state(), dispatch));
  controlsRight.append(start);
  createEffect(() => {
    start.textContent = state().context?.copy.start ?? "Start";
    const currentProvider = provider();
    const autoStartAlreadyAttempted = currentProvider
      ? state().autoStartAttemptedProviderIds.includes(currentProvider.id)
      : false;
    const showStart = canStart() && (currentProvider?.autoStart !== true || autoStartAlreadyAttempted);
    start.hidden = !showStart;
    start.disabled = !showStart;
  });

  const stop = document.createElement("button");
  stop.className = "codex-action codex-circle-action";
  stop.type = "button";
  stop.setAttribute("aria-label", "Stop");
  stop.addEventListener("click", () => void stopProvider(state(), dispatch));
  controlsRight.append(stop);
  createEffect(() => {
    stop.setAttribute("aria-label", state().context?.copy.stop ?? "Stop");
    stop.disabled = !canStop();
  });

  const mic = document.createElement("button");
  mic.className = "codex-action codex-mic";
  mic.type = "button";
  mic.disabled = true;
  mic.textContent = "♩";
  controlsRight.append(mic);
  createEffect(() => {
    mic.setAttribute("aria-label", state().context?.copy.voiceInput ?? "");
  });

  const send = document.createElement("button");
  send.className = "codex-action send-button";
  send.type = "submit";
  send.append(sendIcon());
  controlsRight.append(send);
  createEffect(() => {
    send.disabled = !canSend();
    send.setAttribute("aria-label", state().context?.copy.send ?? "Send");
  });

  const rateLine = document.createElement("div");
  rateLine.className = "rate-line codex-rate-limit-summary";
  rateLine.setAttribute("role", "status");
  composerStack.append(rateLine);
  createEffect(() => {
    renderRateLimitFooter(rateLine, state(), provider()?.displayName ?? renderer);
  });

  return root;
}

function transcriptTurnElement(entry: TranscriptEntry): HTMLDivElement {
  const row = document.createElement("div");
  if (entry.role === "user") {
    const bubble = document.createElement("div");
    bubble.className =
      "codex-user-bubble bg-token-foreground/5 max-w-[77%] min-w-0 overflow-hidden break-words rounded-2xl px-3 py-2 [&_.contain-inline-size]:[contain:initial]";
    const text = document.createElement("div");
    text.className = "text-size-chat mb-px";
    bubble.append(text);
    row.append(bubble);
    return row;
  }

  const content = document.createElement("div");
  row.append(content);
  return row;
}

function updateTranscriptTurn(row: HTMLDivElement, entry: TranscriptEntry): void {
  switch (entry.role) {
    case "user": {
      row.className = "codex-user-turn group flex w-full flex-col items-end justify-end gap-1";
      const text = row.querySelector(".text-size-chat");
      replaceTextWithBreaks(text ?? row, entry.text);
      break;
    }
    case "assistant": {
      row.className = "codex-assistant-turn";
      const content = row.firstElementChild as HTMLDivElement | null;
      if (content) {
        content.className = "codex-assistant-message text-size-chat leading-[calc(var(--codex-chat-font-size)+8px)]";
        replaceTextWithBreaks(content, entry.text);
      }
      break;
    }
    case "notice": {
      row.className = `codex-notice-turn ${entry.tone ?? "warning"}`;
      const content = row.firstElementChild as HTMLDivElement | null;
      if (content) {
        content.className = "codex-notice-content text-size-chat-sm";
        replaceTextWithBreaks(content, entry.text);
      }
      break;
    }
  }
}

function replaceTextWithBreaks(target: Element, text: string): void {
  target.replaceChildren();
  const lines = text.split("\n");
  lines.forEach((line, index) => {
    target.append(document.createTextNode(line));
    if (index < lines.length - 1) {
      target.append(document.createElement("br"));
    }
  });
}

function renderRateLimitFooter(target: HTMLElement, state: SessionState, providerDisplayName: string): void {
  target.replaceChildren();
  target.setAttribute("aria-label", `${providerDisplayName} ${statusLabel(state)}`.trim());

  const heading = document.createElement("span");
  heading.className = "rate-line-heading";
  heading.textContent = state.context?.copy.rateLimits ?? "Rate limits";
  target.append(heading);

  for (const row of state.context?.rateLimitRows ?? []) {
    const separator = document.createElement("span");
    separator.className = "rate-dot";
    separator.setAttribute("aria-hidden", "true");
    separator.textContent = "•";
    target.append(separator, rateLimitRowElement(row, state));
  }
}

function rateLimitRowElement(row: AgentSessionRateLimitRow, state: SessionState): HTMLSpanElement {
  const item = document.createElement("span");
  item.className = "rate-limit-item";

  const label = document.createElement("span");
  label.className = "rate-limit-name";
  label.textContent = row.role === "primary"
    ? state.context?.copy.rateLimitPrimary ?? "Primary"
    : state.context?.copy.rateLimitSecondary ?? "Secondary";

  const percent = document.createElement("span");
  percent.className = "rate-limit-percent";
  percent.textContent = formatRateLimitPercent(row.remainingPercent);

  item.append(label, percent);

  const resetText = formatRateLimitReset(row.resetsAt);
  if (resetText) {
    const reset = document.createElement("span");
    reset.className = "rate-limit-reset";
    reset.textContent = `${state.context?.copy.rateLimitResets ?? "resets"} ${resetText}`;
    item.append(reset);
  }

  return item;
}

function formatRateLimitPercent(value: number): string {
  if (!Number.isFinite(value)) {
    return "100%";
  }
  return `${Math.round(Math.min(Math.max(value, 0), 100))}%`;
}

function formatRateLimitReset(resetsAt: number | undefined): string | null {
  if (resetsAt == null || !Number.isFinite(resetsAt)) {
    return null;
  }
  const date = new Date(resetsAt * 1000);
  if (!Number.isFinite(date.getTime())) {
    return null;
  }
  return new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(date);
}

function sendIcon(): SVGSVGElement {
  const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  icon.setAttribute("width", "14");
  icon.setAttribute("height", "14");
  icon.setAttribute("viewBox", "0 0 14 14");
  icon.setAttribute("fill", "none");
  icon.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", "M7 11.5V2.5M7 2.5L3 6.5M7 2.5L11 6.5");
  path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-width", "1.8");
  path.setAttribute("stroke-linecap", "round");
  path.setAttribute("stroke-linejoin", "round");
  icon.append(path);
  return icon;
}

function codexIconButton(kind: string, text: string, onClick?: () => void): HTMLButtonElement {
  const button = document.createElement("button");
  button.className = `codex-tool codex-tool-${kind}`;
  button.type = "button";
  if (onClick) {
    button.addEventListener("click", onClick);
  } else {
    button.disabled = true;
    button.setAttribute("aria-hidden", "true");
  }
  button.textContent = text;
  return button;
}

const root = document.getElementById("root");
if (root) {
  render(App, root);
}
