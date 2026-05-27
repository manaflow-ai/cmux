import React, { useEffect, useReducer, useRef } from "react";
import { createRoot } from "react-dom/client";
import { subscribeToAgentEvents } from "../shared/bridge";
import { insertComposerToken } from "../shared/composerTokens";
import {
  initialState,
  autoStartProvider,
  canStartProvider,
  canStopProvider,
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
  const canStart = canStartProvider(state);
  const canStop = canStopProvider(state);
  const canSend = state.status === "running" && state.input.trim().length > 0;
  const autoStartAlreadyAttempted = provider ? state.autoStartAttemptedProviderIds.includes(provider.id) : false;
  const showStart = canStart && (provider?.autoStart !== true || autoStartAlreadyAttempted);
  const modelLabel = provider ? codexModelLabel(provider.displayName) : "GPT-5.5";
  const modelBadge = provider ? providerBadgeLabel(provider.displayName) : "C";
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const insertToken = (token: "@" | "$") => {
    const textarea = textareaRef.current;
    const insertion = insertComposerToken({
      text: state.input,
      selectionStart: textarea?.selectionStart ?? state.input.length,
      selectionEnd: textarea?.selectionEnd ?? state.input.length,
      token,
    });
    dispatch({ type: "setInput", input: insertion.text });
    queueMicrotask(() => {
      textareaRef.current?.focus();
      textareaRef.current?.setSelectionRange(insertion.cursor, insertion.cursor);
    });
  };
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
          { className: "composer-frame" },
          React.createElement(
            "div",
            { className: "composer-surface" },
            React.createElement(
              "div",
              { className: "composer-body" },
              React.createElement("textarea", {
                ref: textareaRef,
                className: "prompt-input",
                value: state.input,
                placeholder: state.context?.copy.promptPlaceholder ?? "",
                onChange: (event: React.ChangeEvent<HTMLTextAreaElement>) =>
                  dispatch({ type: "setInput", input: event.target.value }),
              }),
            ),
            React.createElement(
              "div",
              { className: "composer-footer" },
              React.createElement(
                "div",
                { className: "codex-left-rail" },
                React.createElement(
                  "label",
                  { className: "model-picker" },
                  React.createElement("span", { className: "model-icon", "aria-hidden": true }, modelBadge),
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
                React.createElement("span", { className: "composer-separator", "aria-hidden": true }),
                codexIconButton("plus", "+"),
                codexIconButton("mention", "@", () => insertToken("@")),
                codexIconButton("skill", "$", () => insertToken("$")),
              ),
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
                    disabled: !canStop,
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
                  sendIcon(),
                ),
              ),
            ),
          ),
        ),
      ),
      React.createElement(
        "div",
        { className: "rate-line" },
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

function providerBadgeLabel(displayName: string): string {
  const lower = displayName.toLowerCase();
  if (lower.includes("claude")) {
    return "Cl";
  }
  if (lower.includes("open")) {
    return "O";
  }
  if (lower === "pi" || lower.includes(" pi")) {
    return "Pi";
  }
  return displayName.trim().slice(0, 1).toUpperCase() || "C";
}

function sendIcon() {
  return React.createElement(
    "svg",
    { width: "14", height: "14", viewBox: "0 0 14 14", fill: "none", "aria-hidden": true },
    React.createElement("path", {
      d: "M7 11.5V2.5M7 2.5L3 6.5M7 2.5L11 6.5",
      stroke: "currentColor",
      strokeWidth: "1.8",
      strokeLinecap: "round",
      strokeLinejoin: "round",
    }),
  );
}

function codexIconButton(kind: string, text: string, onClick?: () => void) {
  const props: React.ButtonHTMLAttributes<HTMLButtonElement> = {
    className: `codex-tool codex-tool-${kind}`,
    type: "button",
  };
  if (onClick) {
    props.onClick = onClick;
  } else {
    props.disabled = true;
    props["aria-hidden"] = true;
  }
  return React.createElement(
    "button",
    props,
    text,
  );
}

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(React.createElement(App));
}
