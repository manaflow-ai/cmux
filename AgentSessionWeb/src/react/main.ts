import React, { useEffect, useReducer, useRef } from "react";
import { createRoot } from "react-dom/client";
import { subscribeToAgentEvents } from "../shared/bridge";
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
import { PromptEditor, type PromptEditorHandle } from "./proseMirrorPromptEditor";

const h = React.createElement;

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
  return h(SessionSurface, { state, dispatch, renderer: "React" });
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
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const submit = () => void sendInput(state, dispatch);

  return h(
    "section",
    { className: "agent-shell" },
    h(
      "div",
      { className: "agent-log" },
      state.log.map((entry) =>
        h(
          "div",
          { className: `agent-log-line ${entry.level}`, key: entry.id },
          h("span", { className: "agent-log-label" }, entry.level),
          h("span", { className: "agent-log-text" }, entry.text),
        ),
      ),
    ),
    h(
      "div",
      { className: "agent-composer-stack" },
      h(
        "form",
        {
          className: "w-full min-w-0",
          onSubmit: (event: React.FormEvent) => {
            event.preventDefault();
            submit();
          },
        },
        h(
          "div",
          {
            className:
              "relative flex flex-col overflow-y-auto rounded-3xl bg-token-input-background/90 text-token-foreground ring ring-black/10 backdrop-blur-lg shadow-[0_4px_16px_0_rgba(0,0,0,0.05)]",
          },
          h(
            "div",
            { className: "relative z-10 flex min-h-0 flex-1 flex-col" },
            h(PromptEditor, {
              ref: editorRef,
              className: "mb-1 flex-grow overflow-y-auto px-3 pt-4 text-base [&_.ProseMirror]:leading-5",
              minHeight: "2.75rem",
              value: state.input,
              placeholder: state.context?.copy.promptPlaceholder ?? "",
              onTextChange: (input: string) => dispatch({ type: "setInput", input }),
              onSubmit: submit,
            }),
            h(
              "div",
              { className: "composer-footer composer-footer-codex" },
              h(
                "div",
                { className: "flex min-w-0 flex-1 items-center gap-1 overflow-x-auto px-1 py-1 [scrollbar-width:none]" },
                h(
                  "label",
                  { className: "model-picker" },
                  h("span", { className: "model-icon", "aria-hidden": true }, modelBadge),
                  h("span", { className: "model-label" }, modelLabel),
                  h("span", { className: "model-chevron", "aria-hidden": true }, "⌄"),
                  h(
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
                      h("option", { key: item.id, value: item.id }, item.displayName),
                    ),
                  ),
                ),
                h("span", { className: "composer-separator", "aria-hidden": true }),
                codexIconButton("plus", "+"),
                codexIconButton("mention", "@", () => editorRef.current?.insertToken("@")),
                codexIconButton("skill", "$", () => editorRef.current?.insertToken("$")),
              ),
              h(
                "div",
                { className: "flex shrink-0 items-center justify-end gap-2" },
                showStart
                  ? h(
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
                h(
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
                h(
                  "button",
                  {
                    className: "codex-action codex-mic",
                    type: "button",
                    disabled: true,
                    "aria-label": state.context?.copy.voiceInput ?? "",
                  },
                  micIcon(),
                ),
                h(
                  "button",
                  {
                    className: "codex-action send-button",
                    type: "submit",
                    disabled: !canSend,
                    "aria-label": state.context?.copy.send ?? "Send",
                  },
                  sendIcon(),
                ),
              ),
            ),
          ),
        ),
      ),
      h(
        "div",
        { className: "rate-line" },
        h("span", { className: `status-dot ${state.status}`, "aria-hidden": true }),
        h("span", null, `${provider?.displayName ?? renderer} ${statusLabel(state)}`),
        h("span", { className: "rate-dot", "aria-hidden": true }, "•"),
        h("span", null, provider?.transportKind ?? "stdio-jsonrpc"),
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
  return h(
    "svg",
    { width: "14", height: "14", viewBox: "0 0 14 14", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M7 11.5V2.5M7 2.5L3 6.5M7 2.5L11 6.5",
      stroke: "currentColor",
      strokeWidth: "1.8",
      strokeLinecap: "round",
      strokeLinejoin: "round",
    }),
  );
}

function micIcon() {
  return h(
    "svg",
    { width: "16", height: "16", viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M8 2.25a2 2 0 0 0-2 2v3.25a2 2 0 1 0 4 0V4.25a2 2 0 0 0-2-2ZM4 7.5a4 4 0 0 0 8 0M8 11.5v2.25",
      stroke: "currentColor",
      strokeWidth: "1.4",
      strokeLinecap: "round",
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
  return h("button", props, text);
}

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(h(App));
}
