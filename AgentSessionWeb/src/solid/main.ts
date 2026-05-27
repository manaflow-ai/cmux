import { createEffect, createSignal, onCleanup } from "solid-js";
import { render } from "solid-js/web";
import { subscribeToAgentEvents } from "../shared/bridge";
import { insertComposerToken } from "../shared/composerTokens";
import { isComposingEnter } from "../shared/keyboard";
import { codexModelLabel, providerBadgeLabel } from "../shared/providerDisplay";
import {
  initialState,
  autoStartProvider,
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
} from "../shared/sessionModel";
import type { ProviderId } from "../shared/types";

function App() {
  const [state, setState] = createSignal<SessionState>(initialState("solid"));
  const dispatch = (action: Action) => setState((current) => reduceSession(current, action));

  void loadInitialData(dispatch);
  const unsubscribe = subscribeToAgentEvents((event) => dispatch({ type: "event", event }));
  onCleanup(unsubscribe);

  createEffect(() => {
    document.documentElement.dataset.status = state().status;
  });
  createEffect(() => {
    void autoStartProvider(state(), dispatch);
  });

  return SessionSurface({ state, dispatch, renderer: "Solid" });
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

  const log = document.createElement("div");
  log.className = "log";
  root.append(log);
  const logRows = new Map<string, HTMLDivElement>();
  createEffect(() => {
    const entries = state().log.filter((entry) => entry.level !== "info");
    const liveIds = new Set(entries.map((entry) => entry.id));
    for (const [id, row] of logRows) {
      if (!liveIds.has(id)) {
        row.remove();
        logRows.delete(id);
      }
    }
    entries.forEach((entry, index) => {
      let row = logRows.get(entry.id);
      if (!row) {
        row = document.createElement("div");
        const label = document.createElement("span");
        label.className = "log-label";
        const text = document.createElement("span");
        text.className = "log-text";
        row.append(label, text);
        logRows.set(entry.id, row);
      }
      row.className = `log-line ${entry.level}`;
      const label = row.firstElementChild;
      const text = row.lastElementChild;
      if (label?.textContent !== entry.level) {
        label!.textContent = entry.level;
      }
      if (text?.textContent !== entry.text) {
        text!.textContent = entry.text;
      }
      const current = log.children.item(index);
      if (current !== row) {
        log.insertBefore(row, current);
      }
    });
    while (log.children.length > entries.length) {
      log.lastElementChild?.remove();
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
    selectProvider(select.value as ProviderId, dispatch);
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
    select.disabled = state().status === "running" || state().status === "starting" || state().status === "stopping";
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
  rateLine.className = "rate-line";
  composerStack.append(rateLine);
  const statusDot = document.createElement("span");
  statusDot.setAttribute("aria-hidden", "true");
  const statusText = document.createElement("span");
  const rateSeparator = document.createElement("span");
  rateSeparator.className = "rate-dot";
  rateSeparator.setAttribute("aria-hidden", "true");
  rateSeparator.textContent = "•";
  const transport = document.createElement("span");
  rateLine.append(statusDot, statusText, rateSeparator, transport);
  createEffect(() => {
    statusDot.className = `status-dot ${state().status}`;
    statusText.textContent = `${provider()?.displayName ?? renderer} ${statusLabel(state())}`;
    transport.textContent = provider()?.transportKind ?? "stdio-jsonrpc";
  });

  return root;
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
