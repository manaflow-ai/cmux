import { createEffect, createSignal, onCleanup } from "solid-js";
import { render } from "solid-js/web";
import { subscribeToAgentEvents } from "../shared/bridge";
import {
  initialState,
  loadInitialData,
  reduceSession,
  sendInput,
  startProvider,
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
  const canStart = () => state().status === "idle" || state().status === "failed";
  const canSend = () => state().status === "running" && state().input.trim().length > 0;
  const root = document.createElement("section");
  root.className = "agent-shell";

  const toolbar = document.createElement("header");
  toolbar.className = "toolbar";
  root.append(toolbar);

  const rendererMark = document.createElement("div");
  rendererMark.className = "renderer-mark";
  rendererMark.textContent = renderer;
  toolbar.append(rendererMark);

  const select = document.createElement("select");
  select.className = "provider-select";
  select.addEventListener("change", () => {
    dispatch({ type: "selectProvider", providerId: select.value as ProviderId });
  });
  toolbar.append(select);

  createEffect(() => {
    select.replaceChildren();
    for (const item of state().providers) {
      const option = document.createElement("option");
      option.value = item.id;
      option.textContent = item.displayName;
      select.append(option);
    }
    select.value = state().selectedProviderId;
    select.disabled = state().status === "running" || state().status === "starting";
  });

  const status = document.createElement("span");
  toolbar.append(status);
  createEffect(() => {
    status.className = `status-pill ${state().status}`;
    status.textContent = state().status;
  });

  const start = document.createElement("button");
  start.className = "toolbar-button";
  start.addEventListener("click", () => void startProvider(state(), dispatch));
  toolbar.append(start);
  createEffect(() => {
    start.textContent = state().context?.copy.start ?? "Start";
    start.disabled = !canStart();
  });

  const transport = document.createElement("div");
  transport.className = "transport";
  toolbar.append(transport);
  createEffect(() => {
    transport.textContent = provider()?.transportKind ?? "";
  });

  const stop = document.createElement("button");
  stop.className = "toolbar-button";
  stop.addEventListener("click", () => void stopProvider(state(), dispatch));
  toolbar.append(stop);
  createEffect(() => {
    stop.textContent = state().context?.copy.stop ?? "Stop";
    stop.disabled = state().status !== "running";
  });

  const log = document.createElement("div");
  log.className = "log";
  root.append(log);
  createEffect(() => {
    log.replaceChildren();
    for (const entry of state().log) {
      const row = document.createElement("div");
      row.className = `log-line ${entry.level}`;
      const label = document.createElement("span");
      label.className = "log-label";
      label.textContent = entry.level;
      const text = document.createElement("span");
      text.className = "log-text";
      text.textContent = entry.text;
      row.append(label, text);
      log.append(row);
    }
  });

  const form = document.createElement("form");
  form.className = "composer";
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    void sendInput(state(), dispatch);
  });
  root.append(form);

  const textarea = document.createElement("textarea");
  textarea.className = "prompt-input";
  textarea.addEventListener("input", () => dispatch({ type: "setInput", input: textarea.value }));
  form.append(textarea);
  createEffect(() => {
    textarea.placeholder = state().context?.copy.promptPlaceholder ?? "";
    if (textarea.value !== state().input) {
      textarea.value = state().input;
    }
  });

  const send = document.createElement("button");
  send.className = "send-button";
  form.append(send);
  createEffect(() => {
    send.textContent = state().context?.copy.send ?? "Send";
    send.disabled = !canSend();
  });

  return root;
}

const root = document.getElementById("root");
if (root) {
  render(App, root);
}
