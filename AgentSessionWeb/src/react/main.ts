import React, { useEffect, useReducer } from "react";
import { createRoot } from "react-dom/client";
import { subscribeToAgentEvents } from "../shared/bridge";
import {
  initialState,
  autoStartProvider,
  loadInitialData,
  reduceSession,
  sendInput,
  startProvider,
  statusLabel,
  stopProvider,
  type Action,
  type SessionState,
} from "../shared/sessionModel";
import type { ProviderId } from "../shared/types";

function useInitialData(dispatch: React.Dispatch<Action>) {
  useEffect(() => {
    void loadInitialData(dispatch);
  }, [dispatch]);
}

function useNativeEvents(dispatch: React.Dispatch<Action>) {
  useEffect(() => subscribeToAgentEvents((event) => dispatch({ type: "event", event })), [dispatch]);
}

function useAutoStart(state: SessionState, dispatch: React.Dispatch<Action>) {
  useEffect(() => {
    void autoStartProvider(state, dispatch);
  }, [state, dispatch]);
}

function App() {
  const [state, dispatch] = useReducer(reduceSession, initialState("react"));
  useInitialData(dispatch);
  useNativeEvents(dispatch);
  useAutoStart(state, dispatch);
  return React.createElement(SessionSurface, { state, dispatch, renderer: "React" });
}

function SessionSurface({
  state,
  dispatch,
  renderer,
}: {
  state: SessionState;
  dispatch: React.Dispatch<Action>;
  renderer: string;
}) {
  const provider = state.providers.find((item) => item.id === state.selectedProviderId);
  const canStart = (state.status === "idle" || state.status === "failed") && !state.runningSessionId;
  const canSend = state.status === "running" && state.input.trim().length > 0;
  const autoStartAlreadyAttempted = provider ? state.autoStartAttemptedProviderIds.includes(provider.id) : false;
  const showStart = canStart && (provider?.autoStart !== true || autoStartAlreadyAttempted);
  const modelLabel = provider ? codexModelLabel(provider.displayName) : "GPT-5.5";
  return React.createElement(
    "section",
    { className: "agent-shell" },
    React.createElement(
      "div",
      { className: "log" },
      state.log.map((entry) =>
        React.createElement(
          "div",
          { className: `log-line ${entry.level}`, key: entry.id },
          React.createElement("span", { className: "log-label" }, entry.level),
          React.createElement("span", { className: "log-text" }, entry.text),
        ),
      ),
    ),
    React.createElement(
      "div",
      { className: "composer-stack" },
      React.createElement(
        "form",
        {
          className: "composer",
          onSubmit: (event: React.FormEvent) => {
            event.preventDefault();
            void sendInput(state, dispatch);
          },
        },
        React.createElement(
          "div",
          { className: "codex-left-rail" },
          codexIconButton("plus", "+"),
          codexIconButton("globe", "◉"),
          codexIconButton("spark", "✣"),
          codexIconButton("hammer", "⌁"),
          React.createElement(
            "label",
            { className: "model-picker" },
            React.createElement("span", { className: "model-icon", "aria-hidden": true }, "⌁"),
            React.createElement("span", { className: "model-label" }, modelLabel),
            React.createElement("span", { className: "model-chevron", "aria-hidden": true }, "⌄"),
            React.createElement(
              "select",
              {
                className: "provider-select",
                value: state.selectedProviderId,
                disabled: state.status === "running" || state.status === "starting" || state.status === "stopping",
                "aria-label": state.context?.copy.provider ?? "",
                onChange: (event: React.ChangeEvent<HTMLSelectElement>) =>
                  dispatch({ type: "selectProvider", providerId: event.target.value as ProviderId }),
              },
              state.providers.map((item) =>
                React.createElement("option", { key: item.id, value: item.id }, item.displayName),
              ),
            ),
          ),
        ),
        React.createElement("textarea", {
          className: "prompt-input",
          value: state.input,
          placeholder: state.context?.copy.promptPlaceholder ?? "",
          onChange: (event: React.ChangeEvent<HTMLTextAreaElement>) =>
            dispatch({ type: "setInput", input: event.target.value }),
        }),
        React.createElement(
          "div",
          { className: "codex-right-rail" },
          showStart
            ? React.createElement(
                "button",
                {
                  className: "codex-action codex-start",
                  type: "button",
                  disabled: !canStart,
                  onClick: () => void startProvider(state, dispatch),
                },
                state.context?.copy.start ?? "Start",
              )
            : null,
          React.createElement(
            "button",
            {
              className: "codex-action codex-circle-action",
              type: "button",
              disabled: state.status !== "running",
              "aria-label": state.context?.copy.stop ?? "Stop",
              onClick: () => void stopProvider(state, dispatch),
            },
            "",
          ),
          React.createElement(
            "button",
            { className: "codex-action codex-mic", type: "button", disabled: true, "aria-label": state.context?.copy.voiceInput ?? "" },
            "♩",
          ),
          React.createElement(
            "button",
            { className: "codex-action send-button", type: "submit", disabled: !canSend, "aria-label": state.context?.copy.send ?? "Send" },
            "↑",
          ),
        ),
      ),
      React.createElement(
        "div",
        { className: "rate-line" },
        React.createElement("span", { className: "rate-muted" }, state.context?.copy.rateLimits ?? ""),
        React.createElement("span", { className: `status-dot ${state.status}`, "aria-hidden": true }),
        React.createElement("span", null, `${provider?.displayName ?? renderer} ${statusLabel(state)}`),
        React.createElement("span", { className: "rate-dot", "aria-hidden": true }, "•"),
        React.createElement("span", null, provider?.transportKind ?? "stdio-jsonrpc"),
      ),
    ),
  );
}

function codexModelLabel(displayName: string): string {
  if (displayName.toLowerCase() === "codex") {
    return "GPT-5.5";
  }
  return displayName;
}

function codexIconButton(kind: string, text: string) {
  return React.createElement(
    "button",
    { className: `codex-tool codex-tool-${kind}`, type: "button", disabled: true, "aria-hidden": true },
    text,
  );
}

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(React.createElement(App));
}
