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
  const canStart = state.status === "idle" || state.status === "failed";
  const canSend = state.status === "running" && state.input.trim().length > 0;
  const showStart = canStart && provider?.autoStart !== true;
  return React.createElement(
    "section",
    { className: "agent-shell" },
    React.createElement(
      "header",
      { className: "toolbar" },
      React.createElement("div", { className: "renderer-mark" }, renderer),
      React.createElement(
        "div",
        { className: "session-title" },
        React.createElement("span", { className: "provider-name" }, provider?.displayName ?? ""),
        React.createElement("span", { className: "transport" }, provider?.transportKind ?? ""),
      ),
      React.createElement(
        "select",
        {
          className: "provider-select",
          value: state.selectedProviderId,
          disabled: state.status === "running" || state.status === "starting",
          onChange: (event: React.ChangeEvent<HTMLSelectElement>) =>
            dispatch({ type: "selectProvider", providerId: event.target.value as ProviderId }),
        },
        state.providers.map((item) =>
          React.createElement("option", { key: item.id, value: item.id }, item.displayName),
        ),
      ),
      React.createElement("span", { className: `status-pill ${state.status}` }, state.status),
      showStart
        ? React.createElement(
        "button",
        {
          className: "toolbar-button",
          disabled: !canStart,
          onClick: () => void startProvider(state, dispatch),
        },
        state.context?.copy.start ?? "Start",
          )
        : React.createElement("span", { className: "autostart-note", "aria-hidden": true }),
      React.createElement(
        "button",
        {
          className: "toolbar-button",
          disabled: state.status !== "running",
          onClick: () => void stopProvider(state, dispatch),
        },
        state.context?.copy.stop ?? "Stop",
      ),
    ),
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
      "form",
      {
        className: "composer",
        onSubmit: (event: React.FormEvent) => {
          event.preventDefault();
          void sendInput(state, dispatch);
        },
      },
      React.createElement("textarea", {
        className: "prompt-input",
        value: state.input,
        placeholder: state.context?.copy.promptPlaceholder ?? "",
        onChange: (event: React.ChangeEvent<HTMLTextAreaElement>) =>
          dispatch({ type: "setInput", input: event.target.value }),
      }),
      React.createElement(
        "button",
        { className: "send-button", disabled: !canSend },
        state.context?.copy.send ?? "Send",
      ),
    ),
  );
}

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(React.createElement(App));
}
