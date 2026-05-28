import React, { useCallback, useEffect, useLayoutEffect, useReducer, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { subscribeToAgentEvents } from "../shared/bridge";
import { shouldUseSingleLineComposer } from "../shared/composerLayout";
import { renderMarkdownHTML, renderPlainTextHTML } from "../shared/markdown";
import { codexModelLabel, providerBadgeLabel } from "../shared/providerDisplay";
import {
  formatRateLimitPercent,
  formatRateLimitReset,
  formatRateLimitWindow,
  normalizeRateLimitRow,
} from "../shared/rateLimits";
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
import { PromptEditor, type PromptEditorHandle } from "./proseMirrorPromptEditor";

const h = React.createElement;

type ComposerMenuKind = "mention" | "skill" | null;

function useMeasuredComposerLayout(input: string) {
  const [inputWidth, setInputWidth] = useState<number | null>(null);
  const [textWidth, setTextWidth] = useState(0);
  const [inputElement, setInputElement] = useState<HTMLDivElement | null>(null);
  const textMeasureRef = useRef<HTMLSpanElement | null>(null);
  const inputMeasureRef = useCallback((node: HTMLDivElement | null) => {
    setInputElement(node);
  }, []);

  useLayoutEffect(() => {
    const element = inputElement;
    if (!element) {
      return;
    }
    const updateWidth = () => setInputWidth(element.getBoundingClientRect().width);
    updateWidth();
    if (typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(updateWidth);
    observer.observe(element);
    return () => observer.disconnect();
  }, [inputElement]);

  useLayoutEffect(() => {
    const measure = textMeasureRef.current;
    if (!measure) {
      return;
    }
    setTextWidth(measure.getBoundingClientRect().width);
  }, [input]);

  return {
    inputMeasureRef,
    isSingleLine: shouldUseSingleLineComposer({
      composerLayoutMode: "auto-single-line",
      hasVisibleAttachments: false,
      isEditorMultiline: input.includes("\n"),
      isVoiceLayoutActive: false,
      singleLineInputWidth: inputWidth,
      singleLineTextWidth: textWidth,
    }),
    textMeasureRef,
  };
}

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
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const [menuKind, setMenuKind] = useState<ComposerMenuKind>(null);
  const [providerMenuOpen, setProviderMenuOpen] = useState(false);
  const composerLayout = useMeasuredComposerLayout(state.input);
  const isSingleLineComposer = composerLayout.isSingleLine;
  const submit = () => {
    setMenuKind(null);
    setProviderMenuOpen(false);
    void sendInput(state, dispatch);
  };
  const insertComposerMenuItem = (value: string) => {
    editorRef.current?.insertText(value);
    setMenuKind(null);
  };
  const selectProviderMenuItem = (providerId: ProviderId) => {
    selectProvider(providerId, state, dispatch);
    setProviderMenuOpen(false);
  };
  const modelPicker = h(
    "div",
    {
      className: "model-picker-root relative min-w-0",
      onBlur: (event: React.FocusEvent<HTMLDivElement>) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
          setProviderMenuOpen(false);
        }
      },
    },
    h(
      "button",
      {
        className:
          "model-picker border-token-border user-select-none no-drag cursor-interaction flex items-center gap-1 border whitespace-nowrap focus:outline-none disabled:cursor-not-allowed disabled:opacity-40 rounded-full text-token-text-tertiary enabled:hover:bg-token-list-hover-background data-[state=open]:bg-token-list-hover-background border-transparent h-token-button-composer max-w-40 min-w-0 px-2 py-0 text-sm leading-[18px]",
        type: "button",
        disabled: !canSelect,
        "aria-haspopup": "menu",
        "aria-expanded": providerMenuOpen,
        "data-state": providerMenuOpen ? "open" : "closed",
        "data-codex-intelligence-trigger": true,
        "data-selected-reasoning-effort": "high",
        onClick: () => setProviderMenuOpen((open) => canSelect && !open),
        onKeyDown: (event: React.KeyboardEvent<HTMLButtonElement>) => {
          if (event.key === "ArrowDown") {
            event.preventDefault();
            setProviderMenuOpen(canSelect);
          }
        },
      },
      h(
        "span",
        { className: "model-picker-content flex max-w-40 min-w-0 items-center gap-1.5" },
        h(
          "span",
          { className: "model-picker-primary flex min-w-0 items-center gap-1 tabular-nums" },
          h("span", { className: "model-label truncate whitespace-nowrap text-token-foreground" }, modelLabel),
        ),
      ),
      h(
        "span",
        {
          className: "model-chevron composer-footer__secondary-chevron icon-2xs text-token-input-placeholder-foreground",
          "aria-hidden": true,
        },
        chevronIcon(),
      ),
    ),
    providerMenuOpen
      ? h(
          "div",
          {
            className:
              "provider-dropdown _content_1hiti_1 no-drag bg-token-dropdown-background/90 text-token-foreground ring-token-border z-50 m-px flex select-none flex-col overflow-y-auto rounded-xl ring-[0.5px] px-1 py-1 shadow-xl-spread backdrop-blur-sm w-52",
            role: "menu",
            "aria-label": state.context?.copy.provider ?? "",
          },
          h("div", { className: "provider-dropdown-title" }, state.context?.copy.provider ?? "Provider"),
          state.providers.map((item) =>
            h(
              "button",
              {
                key: item.id,
                className:
                  "provider-dropdown-item no-drag text-token-foreground outline-hidden rounded-lg px-[var(--padding-row-x)] py-[var(--padding-row-y)] text-sm",
                type: "button",
                role: "menuitem",
                "data-selected": item.id === state.selectedProviderId ? "true" : undefined,
                onMouseDown: (event: React.MouseEvent<HTMLButtonElement>) => event.preventDefault(),
                onClick: () => selectProviderMenuItem(item.id),
              },
              h(
                "span",
                { className: "provider-dropdown-item-content flex w-full items-center gap-1.5" },
                h("span", { className: "min-w-0 flex-1 truncate" }, item.displayName),
                item.id === state.selectedProviderId
                  ? h("span", { className: "provider-dropdown-check icon-xs shrink-0", "aria-hidden": true }, checkIcon())
                  : null,
              ),
            ),
          ),
        )
      : null,
  );
  const composerInput = h(PromptEditor, {
    ref: editorRef,
    className: isSingleLineComposer
      ? "composer-editor text-base"
      : "composer-editor text-base [&_.ProseMirror]:leading-5",
    minHeight: isSingleLineComposer ? "1.25rem" : "2.75rem",
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
    codexIconButton("context", state.context?.copy.autoContext ?? "Context", ideContextIcon()),
    codexIconButton("tools", state.context?.copy.tools ?? "Tools", skillsIcon()),
    modelPicker,
  );
  const rightActions = h(
    "div",
    { className: "codex-right-rail flex min-w-0 shrink-0 items-center justify-end gap-2" },
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
  const composerInputWrapper = h(
    "div",
    {
      key: "composer-input",
      ref: isSingleLineComposer ? composerLayout.inputMeasureRef : undefined,
      className: isSingleLineComposer
        ? "composer-input-single-line min-w-0"
        : "composer-input-row composer-input-multiline mb-1 flex-grow overflow-y-auto px-3",
    },
    composerInput,
  );
  const composerControls = isSingleLineComposer
    ? h(
        "div",
        {
          className:
            "composer-footer composer-footer-single-line grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2 px-2 py-1",
        },
        leftControls,
        composerInputWrapper,
        rightActions,
      )
    : h(
        "div",
        { className: "relative z-10 flex min-h-0 flex-1 flex-col" },
        composerInputWrapper,
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
      );

  return h(
    "section",
    { className: "agent-shell", "data-codex-window-type": "electron" },
    h(TranscriptThread, { entries: state.transcript }),
    h(
      "div",
      { className: "agent-composer-stack" },
      h(
        "div",
        { className: "relative flex w-full flex-col gap-2" },
        h("span", {
          ref: composerLayout.textMeasureRef,
          className: "composer-single-line-measure",
          "aria-hidden": true,
        }, state.input),
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
                  "codex-composer-surface relative flex flex-col bg-token-input-background/90 text-token-foreground ring ring-black/10 backdrop-blur-lg shadow-[0_4px_16px_0_rgba(0,0,0,0.05)] " +
                  (isSingleLineComposer ? "overflow-visible rounded-full" : "overflow-y-auto rounded-3xl"),
              },
              composerControls,
            ),
          ),
        ),
      ),
      h(RateLimitFooter, { state, providerDisplayName: provider?.displayName ?? renderer }),
    ),
  );
}

function TranscriptThread({ entries }: { entries: TranscriptEntry[] }) {
  return h(
    "div",
    {
      className: "agent-thread",
      "data-empty": entries.length === 0 ? "true" : undefined,
    },
    entries.map((entry) => h(TranscriptTurn, { entry, key: entry.id })),
  );
}

function TranscriptTurn({ entry }: { entry: TranscriptEntry }) {
  switch (entry.role) {
    case "user":
      return h(
        "div",
        { className: "codex-user-turn group flex w-full flex-col items-end justify-end gap-1" },
        h(
          "div",
          {
            className:
              "codex-user-bubble bg-token-foreground/5 max-w-[77%] min-w-0 overflow-hidden break-words rounded-2xl px-3 py-2 [&_.contain-inline-size]:[contain:initial]",
          },
          h("div", {
            className: "text-size-chat mb-px",
            dangerouslySetInnerHTML: { __html: renderPlainTextHTML(entry.text) },
          }),
        ),
      );
    case "assistant":
      return h(
        "div",
        { className: "codex-assistant-turn" },
        h(
          "div",
          {
            className:
              "codex-assistant-message text-size-chat leading-[calc(var(--codex-chat-font-size)+8px)]",
            dangerouslySetInnerHTML: { __html: renderMarkdownHTML(entry.text) },
          },
        ),
      );
    case "notice":
      return h(
        "div",
        { className: `codex-notice-turn ${entry.tone ?? "warning"}` },
        h("div", {
          className: "codex-notice-content text-size-chat-sm",
          dangerouslySetInnerHTML: { __html: renderPlainTextHTML(entry.text) },
        }),
      );
    case "activity":
      return h(
        "div",
        { className: `codex-tool-activity-turn ${entry.activityKind ?? "other"} ${entry.activityStatus ?? "completed"}` },
        h(
          "div",
          {
            className:
              "codex-tool-activity-summary group/collapsed-tool-activity group/summary inline-flex w-fit max-w-full cursor-interaction items-center gap-1 self-start text-left",
          },
          h("span", { className: "codex-tool-activity-icon icon-xs shrink-0", "aria-hidden": true }, activityGlyph(entry)),
          h(
            "span",
            { className: "codex-tool-activity-text shrink overflow-hidden [mask-image:linear-gradient(to_right,black_calc(100%_-_0.25rem),transparent)] [mask-repeat:no-repeat] pr-1" },
            h("span", {
              className: "codex-tool-activity-action",
              dangerouslySetInnerHTML: { __html: renderPlainTextHTML(entry.text) },
            }),
            entry.detail
              ? h("span", {
                  className: "codex-tool-activity-detail",
                  dangerouslySetInnerHTML: { __html: ` ${renderPlainTextHTML(entry.detail)}` },
                })
              : null,
          ),
        ),
        entry.output
          ? h("pre", {
              className: "codex-tool-activity-output text-size-chat-sm",
              dangerouslySetInnerHTML: { __html: renderPlainTextHTML(entry.output) },
            })
          : null,
      );
  }
}

function RateLimitFooter({
  state,
  providerDisplayName,
}: {
  state: SessionState;
  providerDisplayName: string;
}) {
  const rows = state.context?.rateLimitRows ?? [];
  const normalizedRows = rows.map(normalizeRateLimitRow);
  const copy = state.context?.copy;
  const [isOpen, setIsOpen] = useState(false);
  if (normalizedRows.length === 0) {
    return null;
  }
  const rateLimitsLabel = copy?.rateLimits ?? "Rate limits";
  return h(
    "div",
    {
      className: "rate-line codex-rate-limit-summary relative",
      role: "status",
      "aria-label": `${providerDisplayName} ${statusLabel(state)}`.trim(),
      onBlur: (event: React.FocusEvent<HTMLDivElement>) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
          setIsOpen(false);
        }
      },
    },
    h(
      "button",
      {
        className: "rate-limit-trigger rate-limit-trigger-inline flex min-w-0 items-center gap-1",
        type: "button",
        "aria-expanded": isOpen,
        onClick: () => setIsOpen((open) => !open),
      },
      h("span", { className: "rate-line-heading" }, rateLimitsLabel),
      normalizedRows.flatMap((row) => [
        h("span", { key: `${row.role}-separator`, className: "rate-limit-inline-separator", "aria-hidden": true }, "•"),
        h(RateLimitInlineSegment, { key: row.role, row, state }),
      ]),
    ),
    isOpen
      ? h(
          "div",
          {
            className:
              "rate-limit-popover absolute bottom-[calc(100%+6px)] left-0 z-50 flex min-w-56 flex-col gap-1 rounded-xl border border-token-border bg-token-dropdown-background/95 px-3 py-2 text-sm shadow-xl-spread backdrop-blur-sm",
          },
          h("div", { className: "rate-limit-popover-title" }, rateLimitsLabel),
          rows.map((row) => h(RateLimitRow, { key: row.role, row, state })),
        )
      : null,
  );
}

function RateLimitInlineSegment({ row, state }: { row: AgentSessionRateLimitRow; state: SessionState }) {
  const normalized = normalizeRateLimitRow(row);
  const copy = state.context?.copy;
  const fallbackLabel = normalized.role === "primary"
    ? copy?.rateLimitPrimary ?? "Primary"
    : copy?.rateLimitSecondary ?? "Secondary";
  const label = formatRateLimitWindow(normalized.windowDurationMins, fallbackLabel, {
    weekly: copy?.rateLimitWeekly ?? "Weekly",
    monthly: copy?.rateLimitMonthly ?? "Monthly",
  });
  const resetText = formatRateLimitReset(normalized.resetsAt);
  return h(
    "span",
    { className: "rate-limit-inline-segment" },
    h("span", { className: "rate-limit-window" }, label),
    h("span", { className: "rate-limit-percent" }, formatRateLimitPercent(normalized.remainingPercent)),
    resetText
      ? h(
          "span",
          { className: "rate-limit-reset" },
          `${copy?.rateLimitResets ?? "resets"} ${resetText}`,
        )
      : null,
  );
}

function RateLimitRow({ row, state }: { row: AgentSessionRateLimitRow; state: SessionState }) {
  const normalized = normalizeRateLimitRow(row);
  const copy = state.context?.copy;
  const fallbackLabel = normalized.role === "primary"
    ? copy?.rateLimitPrimary ?? "Primary"
    : copy?.rateLimitSecondary ?? "Secondary";
  const label = formatRateLimitWindow(normalized.windowDurationMins, fallbackLabel, {
    weekly: copy?.rateLimitWeekly ?? "Weekly",
    monthly: copy?.rateLimitMonthly ?? "Monthly",
  });
  const resetText = formatRateLimitReset(normalized.resetsAt);
  return h(
    "div",
    { className: "rate-limit-popover-row" },
    h("span", { className: "rate-limit-window" }, label),
    h(
      "span",
      { className: "rate-limit-row-value" },
      h("span", { className: "rate-limit-percent" }, formatRateLimitPercent(normalized.remainingPercent)),
      resetText
        ? h(
            "span",
            { className: "rate-limit-reset" },
            `${copy?.rateLimitResets ?? "resets"} ${resetText}`,
          )
        : null,
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
      { className: "codex-top-tray-panel", "cmdk-root": "", "data-cmdk-root": true },
      h("div", { className: "codex-top-tray-title" }, kind === "mention"
        ? copy?.mentionMenuTitle ?? "Mention"
        : copy?.skillMenuTitle ?? "Skills"),
      h(
        "div",
        { className: "codex-top-tray-list", "cmdk-list": "", "data-cmdk-list": true },
        items.map((item) =>
          h(
            "button",
            {
              key: item.id,
              className: "codex-top-tray-item",
              type: "button",
              "cmdk-item": "",
              "data-list-navigation-item": true,
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
    { className: "icon-sm", width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M9.33467 16.6663V4.93978L4.6374 9.63704L4.1667 9.16634L3.69599 8.69661L9.52998 2.86263L9.63447 2.77767C9.8925 2.60753 10.2433 2.63564 10.4704 2.86263L16.3034 8.69661L16.3884 8.80111C16.5588 9.05922 16.5306 9.40982 16.3034 9.63704C16.0762 9.86414 15.7255 9.89242 15.4675 9.722L15.363 9.63704L10.6647 4.9388V16.6663C10.6647 17.0336 10.367 17.3314 9.99971 17.3314C9.63259 17.3312 9.33467 17.0335 9.33467 16.6663ZM4.6374 9.63704C4.3777 9.89674 3.95569 9.89674 3.69599 9.63704C3.43657 9.37744 3.43668 8.95628 3.69599 8.69661L4.6374 9.63704Z",
      fill: "currentColor",
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

function speedometerIcon() {
  return h(
    "svg",
    { width: "16", height: "16", viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M2.5 10.25a5.5 5.5 0 1 1 11 0M8 10.25l2.45-3.05M4.35 10.25h7.3",
      stroke: "currentColor",
      strokeWidth: "1.35",
      strokeLinecap: "round",
      strokeLinejoin: "round",
    }),
  );
}

function chevronIcon() {
  return h(
    "svg",
    { className: "icon-2xs", width: "20", height: "21", viewBox: "0 0 20 21", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M15.2793 7.71101C15.539 7.45131 15.961 7.45131 16.2207 7.71101C16.4804 7.97071 16.4804 8.39272 16.2207 8.65242L10.4707 14.4024C10.211 14.6621 9.78902 14.6621 9.52932 14.4024L3.77932 8.65242L3.69436 8.54792C3.52385 8.28979 3.55205 7.93828 3.77932 7.71101C4.00659 7.48374 4.3581 7.45554 4.61623 7.62605L4.72073 7.71101L10 12.9903L15.2793 7.71101Z",
      fill: "currentColor",
      stroke: "currentColor",
      strokeWidth: "0.6",
    }),
  );
}

function checkIcon() {
  return h(
    "svg",
    { width: "17", height: "17", viewBox: "0 0 17 17", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M12.8961 3.64101C13.1297 3.41418 13.4984 3.37523 13.7779 3.56581C14.0571 3.75635 14.1554 4.11331 14.0299 4.41347L13.9615 4.53847L7.71151 13.7045C7.59411 13.8767 7.4063 13.9877 7.19881 14.0072C6.99136 14.0267 6.78564 13.9533 6.63826 13.806L2.88826 10.056L2.79842 9.9457C2.6192 9.67407 2.64927 9.30496 2.88826 9.06581C3.12738 8.82669 3.49647 8.79676 3.76815 8.97597L3.8785 9.06581L7.03084 12.2182L12.8053 3.74941L12.8961 3.64101Z",
      fill: "currentColor",
    }),
  );
}

function plusIcon() {
  return h(
    "svg",
    { className: "icon-sm", width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M9.33496 16.5V10.665H3.5C3.13273 10.665 2.83496 10.3673 2.83496 10C2.83496 9.63273 3.13273 9.33496 3.5 9.33496H9.33496V3.5C9.33496 3.13273 9.63273 2.83496 10 2.83496C10.3673 2.83496 10.665 3.13273 10.665 3.5V9.33496H16.5L16.6338 9.34863C16.9369 9.41057 17.165 9.67857 17.165 10C17.165 10.3214 16.9369 10.5894 16.6338 10.6514L16.5 10.665H10.665V16.5C10.665 16.8673 10.3673 17.165 10 17.165C9.63273 17.165 9.33496 16.8673 9.33496 16.5Z",
      fill: "currentColor",
    }),
  );
}

function globeIcon() {
  return h(
    "svg",
    { className: "icon-sm", width: "20", height: "20", viewBox: "0 0 20 20", fill: "currentColor", "aria-hidden": true },
    h("path", {
      d: "M10 2.125C14.3492 2.125 17.875 5.65076 17.875 10C17.875 14.3492 14.3492 17.875 10 17.875C5.65076 17.875 2.125 14.3492 2.125 10C2.125 5.65076 5.65076 2.125 10 2.125ZM7.88672 10.625C7.94334 12.3161 8.22547 13.8134 8.63965 14.9053C8.87263 15.5194 9.1351 15.9733 9.39453 16.2627C9.65437 16.5524 9.86039 16.625 10 16.625C10.1396 16.625 10.3456 16.5524 10.6055 16.2627C10.8649 15.9733 11.1274 15.5194 11.3604 14.9053C11.7745 13.8134 12.0567 12.3161 12.1133 10.625H7.88672ZM3.40527 10.625C3.65313 13.2734 5.45957 15.4667 7.89844 16.2822C7.7409 15.997 7.5977 15.6834 7.4707 15.3486C6.99415 14.0923 6.69362 12.439 6.63672 10.625H3.40527ZM13.3633 10.625C13.3064 12.439 13.0059 14.0923 12.5293 15.3486C12.4022 15.6836 12.2582 15.9969 12.1006 16.2822C14.5399 15.467 16.3468 13.2737 16.5947 10.625H13.3633ZM12.1006 3.7168C12.2584 4.00235 12.4021 4.31613 12.5293 4.65137C13.0059 5.90775 13.3064 7.56102 13.3633 9.375H16.5947C16.3468 6.72615 14.54 4.53199 12.1006 3.7168ZM10 3.375C9.86039 3.375 9.65437 3.44756 9.39453 3.7373C9.1351 4.02672 8.87263 4.48057 8.63965 5.09473C8.22547 6.18664 7.94334 7.68388 7.88672 9.375H12.1133C12.0567 7.68388 11.7745 6.18664 11.3604 5.09473C11.1274 4.48057 10.8649 4.02672 10.6055 3.7373C10.3456 3.44756 10.1396 3.375 10 3.375ZM7.89844 3.7168C5.45942 4.53222 3.65314 6.72647 3.40527 9.375H6.63672C6.69362 7.56102 6.99415 5.90775 7.4707 4.65137C7.59781 4.31629 7.74073 4.00224 7.89844 3.7168Z",
    }),
  );
}

function ideContextIcon() {
  return h(
    "svg",
    { className: "icon-sm", width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M10.6878 9.46029L10.8421 9.49545L17.2913 11.43L17.4642 11.4974C18.2215 11.8649 18.2705 12.9544 17.5492 13.388L17.3822 13.4701L14.5872 14.5872L13.4701 17.3822C13.1135 18.2734 11.8913 18.2756 11.4974 17.4642L11.43 17.2913L9.49544 10.8421C9.26342 10.0687 9.92452 9.34418 10.6878 9.46029ZM12.4984 16.2288L13.3929 13.9954L13.4388 13.8949C13.5579 13.6675 13.7549 13.4891 13.9954 13.3929L16.2288 12.4984L10.9007 10.9007L12.4984 16.2288ZM5.90365 12.9749C6.16329 12.7153 6.58436 12.7154 6.84408 12.9749C7.10378 13.2346 7.10378 13.6557 6.84408 13.9154L5.0765 15.6829C4.8168 15.9426 4.39577 15.9426 4.13607 15.6829C3.87654 15.4232 3.87643 15.0022 4.13607 14.7425L5.90365 12.9749ZM2.83724 7.3265L5.25228 7.97299L5.37826 8.02084C5.65484 8.1591 5.80597 8.47712 5.72298 8.78744C5.63984 9.09774 5.34997 9.298 5.04134 9.27963L4.90853 9.25814L2.49349 8.61068L2.36752 8.56283C2.09082 8.42452 1.93961 8.10666 2.02279 7.79623C2.10599 7.4859 2.39574 7.28652 2.70443 7.30502L2.83724 7.3265ZM14.847 4.05111C15.1051 3.88059 15.4556 3.90894 15.6829 4.13607C15.9426 4.39577 15.9426 4.8168 15.6829 5.0765L13.9154 6.84408C13.6557 7.10378 13.2346 7.10378 12.9749 6.84408C12.7154 6.58437 12.7153 6.16329 12.9749 5.90365L14.7425 4.13607L14.847 4.05111ZM7.79623 2.02279C8.15098 1.92773 8.51562 2.13874 8.61068 2.49349L9.25814 4.90853L9.27962 5.04135C9.298 5.34998 9.09774 5.63984 8.78744 5.72299C8.47713 5.80592 8.15908 5.65484 8.02084 5.37826L7.97298 5.25228L7.3265 2.83724L7.30502 2.70443C7.28652 2.39577 7.48595 2.10603 7.79623 2.02279Z",
      fill: "currentColor",
    }),
  );
}

function skillsIcon() {
  return h(
    "svg",
    { className: "icon-sm", width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M9.79 18.5102C9.48333 18.6969 9.15333 18.7869 8.8 18.7802C8.45333 18.7736 8.13 18.6669 7.83 18.4602L4.35 16.0802C4.07666 15.8936 3.86333 15.6569 3.71 15.3702C3.55666 15.0836 3.48 14.7802 3.48 14.4602V6.53024C3.48 6.20358 3.55333 5.90691 3.7 5.64024C3.85333 5.37358 4.07333 5.15358 4.36 4.98024L10.08 1.46024C10.4067 1.26024 10.76 1.16358 11.14 1.17024C11.52 1.17024 11.87 1.27691 12.19 1.49024L15.71 3.89024C15.97 4.07691 16.17 4.30024 16.31 4.56024C16.45 4.81358 16.52 5.09358 16.52 5.40024V13.2902C16.52 13.6236 16.4367 13.9402 16.27 14.2402C16.1033 14.5402 15.8733 14.7769 15.58 14.9502L9.79 18.5102ZM14.38 4.66024L11.42 2.64024C11.3267 2.57358 11.2233 2.54024 11.11 2.54024C11.0033 2.53358 10.9033 2.56024 10.81 2.62024L5.5 5.89024L8.77 8.11024L14.38 4.66024ZM8.14 9.33025L4.86 7.11024V10.2102L8.14 12.4502V9.33025ZM8.14 14.0402L4.86 11.8002V14.4602C4.86 14.5602 4.88 14.6536 4.92 14.7402C4.96 14.8202 5.02333 14.8902 5.11 14.9502L8.14 17.0202V14.0402ZM15.14 8.89024V5.81024L9.52 9.26025V12.3502L15.14 8.89024ZM14.86 13.7902C14.9533 13.7302 15.0233 13.6602 15.07 13.5802C15.1167 13.4936 15.14 13.3969 15.14 13.2902V10.4802L9.52 13.9402V17.0702L14.86 13.7902Z",
      fill: "currentColor",
    }),
  );
}

function activityGlyph(entry: TranscriptEntry): string {
  if (entry.activityStatus === "stopped" || entry.activityStatus === "failed") {
    return "!";
  }
  switch (entry.activityKind) {
    case "command":
      return "$";
    case "fileChange":
      return "+";
    default:
      return "*";
  }
}

function codexIconButton(kind: string, ariaLabel: string, child: React.ReactNode, onClick?: () => void) {
  const props: React.ButtonHTMLAttributes<HTMLButtonElement> = {
    className: `codex-tool codex-tool-${kind} size-token-button-composer-sm rounded-full`,
    type: "button",
    "aria-label": ariaLabel,
  };
  if (onClick) {
    props.onClick = onClick;
  } else {
    props.disabled = true;
  }
  return h("button", props, child);
}

const root = document.getElementById("root");
if (root) {
  createRoot(root).render(h(App));
}
