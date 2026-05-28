import React, { useEffect, useReducer, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { subscribeToAgentEvents } from "../shared/bridge";
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
} from "../shared/sessionModel";
import type { ProviderId } from "../shared/types";
import { PromptEditor, type PromptEditorHandle } from "./proseMirrorPromptEditor";

const h = React.createElement;

type ComposerMenuKind = "mention" | "skill" | null;

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
  }, [
    state.autoStartAttemptedProviderIds,
    state.context,
    state.providers,
    state.runningSessionId,
    state.selectedProviderId,
    state.status,
    dispatch,
  ]);
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
  const canSelect = canSelectProvider(state);
  const canStart = canStartProvider(state);
  const canStop = canStopProvider(state);
  const canSend = state.status === "running" && state.input.length > 0;
  const autoStartAlreadyAttempted = provider ? state.autoStartAttemptedProviderIds.includes(provider.id) : false;
  const showStart = canStart && (provider?.autoStart !== true || autoStartAlreadyAttempted);
  const modelLabel = codexModelLabel(provider);
  const visibleLogEntries = state.log.filter((entry) => entry.level !== "info");
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const [menuKind, setMenuKind] = useState<ComposerMenuKind>(null);
  const submit = () => {
    setMenuKind(null);
    void sendInput(state, dispatch);
  };
  const insertComposerMenuItem = (value: string) => {
    editorRef.current?.insertText(value);
    setMenuKind(null);
  };
  const modelPicker = h(
    "label",
    { className: "model-picker h-token-button-composer max-w-40 rounded-full px-2 py-0 text-sm leading-[18px]" },
    h("span", { className: "model-label composer-footer__label--sm" }, modelLabel),
    h("span", { className: "model-chevron composer-footer__secondary-chevron", "aria-hidden": true }, chevronIcon()),
    h(
      "select",
      {
        className: "provider-select",
        value: state.selectedProviderId,
        disabled: !canSelect,
        "aria-label": state.context?.copy.provider ?? "",
        onChange: (event: React.ChangeEvent<HTMLSelectElement>) =>
          selectProvider(event.target.value as ProviderId, state, dispatch),
      },
      state.providers.map((item) =>
        h("option", { key: item.id, value: item.id }, item.displayName),
      ),
    ),
  );
  const composerInput = h(PromptEditor, {
    ref: editorRef,
    className: "composer-editor text-base [&_.ProseMirror]:leading-5",
    minHeight: "2.75rem",
    value: state.input,
    ariaLabel: state.context?.copy.promptPlaceholder ?? "",
    placeholder: state.context?.copy.promptPlaceholder ?? "",
    onTextChange: (input: string) => dispatch({ type: "setInput", input }),
    onSubmit: submit,
    onTriggerToken: (token: "@" | "$") => setMenuKind(token === "@" ? "mention" : "skill"),
  });
  const leftControls = h(
    "div",
    { className: "codex-left-rail flex min-w-0 items-center gap-[5px]" },
    codexIconButton("plus", state.context?.copy.attachFile ?? "Attach file", plusIcon()),
    codexIconButton("browse", state.context?.copy.browseWeb ?? "Browse web", globeIcon()),
    codexIconButton("context", state.context?.copy.autoContext ?? "Context", sparkleIcon()),
    codexIconButton("tools", state.context?.copy.tools ?? "Tools", hammerIcon()),
    modelPicker,
  );
  const rightActions = h(
    "div",
    { className: "codex-right-rail flex shrink-0 items-center gap-2" },
    showStart
      ? h(
          "button",
          {
            className: "codex-action codex-start h-token-button-composer rounded-full px-3 py-0",
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
        className: "codex-action codex-circle-action size-token-button-composer rounded-full",
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
        className: "codex-action codex-mic size-token-button-composer rounded-full",
        type: "button",
        disabled: true,
        "aria-label": state.context?.copy.voiceInput ?? "",
      },
      micIcon(),
    ),
    h(
      "button",
      {
        className: "codex-action send-button size-token-button-composer rounded-full",
        type: "submit",
        disabled: !canSend,
        "aria-label": state.context?.copy.send ?? "Send",
      },
      sendIcon(),
    ),
  );

  return h(
    "section",
    { className: "agent-shell", "data-codex-window-type": "electron" },
    h(
      "div",
      { className: "agent-log" },
      visibleLogEntries.map((entry) =>
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
        "div",
        { className: "relative flex w-full flex-col gap-2" },
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
            { className: "codex-composer-frame relative" },
            menuKind
              ? h(ComposerTopTray, {
                  kind: menuKind,
                  state,
                  onChoose: insertComposerMenuItem,
                })
              : null,
            h(
              "div",
              {
                className:
                  "codex-composer-surface relative flex flex-col overflow-visible rounded-3xl bg-token-input-background/90 text-token-foreground ring ring-black/10 backdrop-blur-lg shadow-[0_4px_16px_0_rgba(0,0,0,0.05)]",
              },
              h(
                "div",
                { className: "relative z-10 flex min-h-0 flex-1 flex-col" },
                h(
                  "div",
                  { className: "composer-input-row mb-1 flex-grow overflow-y-auto px-3" },
                  composerInput,
                ),
                h(
                  "div",
                  {
                    className:
                      "composer-footer composer-footer-codex grid grid-cols-[minmax(0,auto)_auto_minmax(0,1fr)] items-center gap-[5px] mb-2 px-2",
                  },
                  leftControls,
                  h("div", { className: "flex items-center" }),
                  h(
                    "div",
                    { className: "flex w-full min-w-0 items-center justify-end gap-2" },
                    h("div", { className: "flex min-w-0 flex-1 justify-end" }),
                    rightActions,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      h(
        "div",
        {
          className: "rate-line",
          role: "status",
          "aria-label": `${provider?.displayName ?? renderer} ${statusLabel(state)} ${provider?.transportKind ?? ""}`.trim(),
        },
        h("span", null, state.context?.copy.rateLimits ?? "Rate limits"),
        h("span", { className: "rate-dot", "aria-hidden": true }, "•"),
        h("span", null, `${provider?.displayName ?? renderer} ${statusLabel(state)}`),
      ),
    ),
  );
}

function ComposerTopTray({
  kind,
  state,
  onChoose,
}: {
  kind: Exclude<ComposerMenuKind, null>;
  state: SessionState;
  onChoose: (value: string) => void;
}) {
  const copy = state.context?.copy;
  const items = kind === "mention"
    ? [
        state.context?.workingDirectory
          ? {
              id: "workspace",
              icon: "@",
              label: copy?.mentionCurrentWorkspace ?? "Current workspace",
              detail: basename(state.context.workingDirectory),
              value: `@${state.context.workingDirectory}`,
            }
          : null,
        ...state.providers.map((provider) => ({
          id: provider.id,
          icon: providerBadgeLabel(provider),
          label: provider.displayName,
          detail: provider.executableName,
          value: `@${provider.displayName}`,
        })),
      ].filter((item): item is ComposerMenuItem => Boolean(item))
    : [
        {
          id: "plan",
          icon: "$",
          label: copy?.skillPlan ?? "Plan",
          detail: "$plan",
          value: "$plan",
        },
        {
          id: "review",
          icon: "$",
          label: copy?.skillCodeReview ?? "Code review",
          detail: "$codex-review",
          value: "$codex-review",
        },
        {
          id: "research",
          icon: "$",
          label: copy?.skillResearch ?? "Research",
          detail: "$research",
          value: "$research",
        },
      ];

  return h(
    "div",
    { className: "codex-top-tray-shell absolute z-20" },
    h(
      "div",
      { className: "codex-top-tray-panel", "data-cmdk-root": true },
      h("div", { className: "codex-top-tray-title" }, kind === "mention"
        ? copy?.mentionMenuTitle ?? "Mention"
        : copy?.skillMenuTitle ?? "Skills"),
      h(
        "div",
        { className: "codex-top-tray-list", "data-cmdk-list": true },
        items.map((item) =>
          h(
            "button",
            {
              key: item.id,
              className: "codex-top-tray-item",
              type: "button",
              "cmdk-item": true,
              onMouseDown: (event: React.MouseEvent<HTMLButtonElement>) => event.preventDefault(),
              onClick: () => onChoose(item.value),
            },
            h("span", { className: "codex-top-tray-icon", "aria-hidden": true }, item.icon),
            h(
              "span",
              { className: "codex-top-tray-copy" },
              h("span", { className: "codex-top-tray-label" }, item.label),
              h("span", { className: "codex-top-tray-detail" }, item.detail),
            ),
          ),
        ),
      ),
    ),
  );
}

type ComposerMenuItem = {
  detail: string;
  icon: string;
  id: string;
  label: string;
  value: string;
};

function basename(path: string): string {
  const segments = path.split("/").filter(Boolean);
  return segments[segments.length - 1] ?? path;
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

function chevronIcon() {
  return h(
    "svg",
    { width: "12", height: "12", viewBox: "0 0 12 12", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M3.25 4.75 6 7.5l2.75-2.75",
      stroke: "currentColor",
      strokeWidth: "1.4",
      strokeLinecap: "round",
      strokeLinejoin: "round",
    }),
  );
}

function plusIcon() {
  return h(
    "svg",
    { width: "16", height: "16", viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M8 3.25v9.5M3.25 8h9.5",
      stroke: "currentColor",
      strokeWidth: "1.6",
      strokeLinecap: "round",
    }),
  );
}

function globeIcon() {
  return h(
    "svg",
    { width: "16", height: "16", viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M2.25 8h11.5M8 2.25a5.75 5.75 0 1 1 0 11.5M8 2.25a8.5 8.5 0 0 1 0 11.5M8 2.25a8.5 8.5 0 0 0 0 11.5",
      stroke: "currentColor",
      strokeWidth: "1.25",
      strokeLinecap: "round",
    }),
  );
}

function sparkleIcon() {
  return h(
    "svg",
    { width: "16", height: "16", viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M8 1.9 9.05 5.4 12.1 8 9.05 10.6 8 14.1 6.95 10.6 3.9 8 6.95 5.4 8 1.9ZM3.25 2.75l.38 1.18 1.12.42-1.12.42-.38 1.18-.38-1.18-1.12-.42 1.12-.42.38-1.18ZM12.8 2.75l.32 1 .95.35-.95.35-.32 1-.32-1-.95-.35.95-.35.32-1Z",
      stroke: "currentColor",
      strokeWidth: "1.15",
      strokeLinecap: "round",
      strokeLinejoin: "round",
    }),
  );
}

function hammerIcon() {
  return h(
    "svg",
    { width: "16", height: "16", viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
    h("path", {
      d: "m9.5 3.25 3.25 3.25M2.75 13.25l4.7-4.7M7.05 8.15l.8.8M6.1 4.05 8.95 1.9l2.85 2.85-2.15 2.85L6.1 4.05Z",
      stroke: "currentColor",
      strokeWidth: "1.25",
      strokeLinecap: "round",
      strokeLinejoin: "round",
    }),
  );
}

function codexIconButton(kind: string, ariaLabel: string, child: React.ReactNode, onClick?: () => void) {
  const props: React.ButtonHTMLAttributes<HTMLButtonElement> = {
    className: `codex-tool codex-tool-${kind} size-token-button-composer-sm rounded-full`,
    type: "button",
    "aria-label": ariaLabel,
    disabled: onClick === undefined,
  };
  if (onClick) {
    props.onClick = onClick;
  }
  return h("button", props, child);
}

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(h(App));
}
