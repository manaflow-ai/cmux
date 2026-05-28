import React, { useCallback, useEffect, useLayoutEffect, useReducer, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { callNative, subscribeToAgentEvents } from "../shared/bridge";
import { shouldUseSingleLineComposer } from "../shared/composerLayout";
import {
  computeFooterCollapse,
  footerCollapseStatesEqual,
  initialFooterCollapseState,
  type FooterCollapseState,
} from "../shared/footerCollapse";
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
  loadInitialData,
  messageForError,
  reduceSession,
  sendInput,
  selectProvider,
  startProvider,
  statusLabel,
  type Action,
  type SessionState,
  type TranscriptEntry,
} from "../shared/sessionModel";
import type { AgentSessionRateLimitRow, ProviderId } from "../shared/types";
import {
  PromptEditor,
  type PromptAutocompleteState,
  type PromptEditorHandle,
  type PromptMention,
} from "./proseMirrorPromptEditor";

const h = React.createElement;

const CODEX_BUTTON_BASE =
  "border-token-border user-select-none no-drag cursor-interaction flex items-center gap-1 border whitespace-nowrap focus:outline-none disabled:cursor-not-allowed disabled:opacity-40";
const CODEX_BUTTON_GHOST =
  "text-token-text-tertiary enabled:hover:bg-token-list-hover-background data-[state=open]:bg-token-list-hover-background border-transparent";
const CODEX_BUTTON_COMPOSER = "h-token-button-composer px-2 py-0 text-sm leading-[18px]";
const CODEX_BUTTON_COMPOSER_SM = "h-token-button-composer-sm px-1.5 py-0 text-sm leading-[18px]";
const CODEX_BUTTON_UNIFORM = "aspect-square items-center justify-center !px-0";
const CODEX_SUBMIT_BUTTON =
  "focus-visible:outline-token-button-background cursor-interaction size-token-button-composer flex items-center justify-center rounded-full p-0.5 transition-opacity focus-visible:outline-2 bg-token-foreground";

type ComposerMenuKind = "mention" | "skill" | null;

type FooterControlSpec = {
  canHideLabel: boolean;
  enabled: boolean;
  id: string;
};

type PickedLocalFile = {
  fsPath?: string;
  label?: string;
  path: string;
};

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

function useMeasuredFooterControlCollapse(specs: FooterControlSpec[]) {
  const [collapseState, setCollapseState] = useState<FooterCollapseState>(() => initialFooterCollapseState(specs));
  const containerRef = useRef<HTMLDivElement | null>(null);
  const itemRefs = useRef(new Map<string, HTMLElement>());
  const expandedWidths = useRef(new Map<string, number>());
  const compactWidths = useRef(new Map<string, number>());
  const specsRef = useRef(specs);
  const collapseStateRef = useRef(collapseState);
  specsRef.current = specs;
  collapseStateRef.current = collapseState;

  const measure = useCallback(() => {
    const container = containerRef.current;
    if (!container) {
      return;
    }
    const items = specsRef.current.map((spec) => {
      const element = itemRefs.current.get(spec.id) ?? null;
      const width = element?.offsetWidth ?? 0;
      if (width > 0) {
        if (collapseStateRef.current[spec.id]?.hideLabel === true) {
          compactWidths.current.set(spec.id, width);
        } else {
          expandedWidths.current.set(spec.id, width);
        }
      }
      const expandedWidth = expandedWidths.current.get(spec.id) ?? compactWidths.current.get(spec.id) ?? width;
      const measuredCompactWidth = compactWidths.current.get(spec.id);
      const compactWidth = spec.canHideLabel
        ? Math.min(expandedWidth, measuredCompactWidth ?? expandedWidth)
        : expandedWidth;
      return {
        ...spec,
        compactWidth,
        expandedWidth,
        hasMeasuredCompactWidth: measuredCompactWidth != null,
      };
    });
    const nextState = computeFooterCollapse({
      availableWidth: container.getBoundingClientRect().width,
      gap: cssPixelValue(window.getComputedStyle(container).columnGap) ??
        cssPixelValue(window.getComputedStyle(container).gap) ??
        0,
      items,
      previousState: collapseStateRef.current,
    });
    if (!footerCollapseStatesEqual(nextState, collapseStateRef.current)) {
      setCollapseState(nextState);
    }
  }, []);

  const setContainerRef = useCallback((node: HTMLDivElement | null) => {
    containerRef.current = node;
    if (node) {
      measure();
    }
  }, [measure]);

  const setItemRef = useCallback((id: string, node: HTMLElement | null) => {
    if (node) {
      itemRefs.current.set(id, node);
      measure();
    } else {
      itemRefs.current.delete(id);
    }
  }, [measure]);

  useLayoutEffect(() => {
    measure();
  }, [measure, specs, collapseState]);

  useLayoutEffect(() => {
    if (typeof ResizeObserver === "undefined") {
      return;
    }
    const observer = new ResizeObserver(measure);
    if (containerRef.current) {
      observer.observe(containerRef.current);
    }
    for (const element of itemRefs.current.values()) {
      observer.observe(element);
    }
    return () => observer.disconnect();
  }, [measure, specs, collapseState]);

  return {
    state: collapseState,
    setContainerRef,
    setItemRef,
  };
}

function cssPixelValue(value: string): number | null {
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : null;
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
  const canSend = state.status === "running" && state.input.length > 0;
  const autoStartAlreadyAttempted = provider ? state.autoStartAttemptedProviderIds.includes(provider.id) : false;
  const showStart = canStart && (provider?.autoStart !== true || autoStartAlreadyAttempted);
  const modelLabel = codexModelLabel(provider);
  const reasoningEffortLabel =
    provider?.id === "codex" ? (state.context?.copy.reasoningEffortHigh ?? "High") : null;
  const footerCollapse = useMeasuredFooterControlCollapse([{
    canHideLabel: reasoningEffortLabel != null,
    enabled: provider != null,
    id: "intelligence",
  }]);
  const intelligenceCollapse = footerCollapse.state.intelligence ?? { hideControl: false, hideLabel: false };
  const editorRef = useRef<PromptEditorHandle | null>(null);
  const [menuKind, setMenuKind] = useState<ComposerMenuKind>(null);
  const [menuQuery, setMenuQuery] = useState("");
  const [menuIndex, setMenuIndex] = useState(0);
  const [providerMenuOpen, setProviderMenuOpen] = useState(false);
  const [addContextMenuOpen, setAddContextMenuOpen] = useState(false);
  const [isPickingFiles, setIsPickingFiles] = useState(false);
  const composerLayout = useMeasuredComposerLayout(state.input);
  const isSingleLineComposer = composerLayout.isSingleLine;
  const menuItems = menuKind ? composerMenuItems(menuKind, state, menuQuery) : [];
  const highlightedMenuIndex = menuItems.length === 0 ? -1 : Math.min(menuIndex, menuItems.length - 1);
  const submit = () => {
    setMenuKind(null);
    setMenuQuery("");
    setProviderMenuOpen(false);
    setAddContextMenuOpen(false);
    void sendInput(state, dispatch);
  };
  const insertComposerMenuItem = (item: ComposerMenuItem) => {
    editorRef.current?.insertMention(item.mention);
    setMenuKind(null);
    setMenuQuery("");
    setMenuIndex(0);
    setAddContextMenuOpen(false);
  };
  const pickLocalFiles = async () => {
    if (isPickingFiles) {
      return;
    }
    setIsPickingFiles(true);
    setMenuKind(null);
    setMenuQuery("");
    setMenuIndex(0);
    setAddContextMenuOpen(false);
    try {
      const result = await callNative<{ files?: PickedLocalFile[] }>("app.pickFiles");
      const mentions = (result.files ?? [])
        .filter((file) => file.path.trim().length > 0)
        .map((file): PromptMention => {
          const label = file.label && file.label.trim().length > 0 ? file.label : basename(file.path);
          return {
            kind: "at",
            label,
            name: label,
            path: file.path,
            fsPath: file.fsPath ?? file.path,
          };
        });
      editorRef.current?.insertMentions(mentions);
    } catch (error) {
      dispatch({ type: "failed", message: messageForError(error, state) });
    } finally {
      setIsPickingFiles(false);
    }
  };
  const updateComposerAutocomplete = (autocomplete: PromptAutocompleteState | null) => {
    if (!autocomplete) {
      setMenuKind(null);
      setMenuQuery("");
      setMenuIndex(0);
      return;
    }
    setMenuKind(autocomplete.kind);
    setMenuQuery(autocomplete.query);
    setMenuIndex(0);
  };
  const handleComposerAutocompleteKey = (key: "ArrowDown" | "ArrowUp" | "Enter" | "Tab" | "Escape"): boolean => {
    if (!menuKind) {
      return false;
    }
    if (key === "Escape") {
      setMenuKind(null);
      setMenuQuery("");
      setMenuIndex(0);
      return true;
    }
    if (menuItems.length === 0) {
      return key === "Enter" || key === "Tab";
    }
    if (key === "ArrowDown") {
      setMenuIndex((index) => (index + 1) % menuItems.length);
      return true;
    }
    if (key === "ArrowUp") {
      setMenuIndex((index) => (index - 1 + menuItems.length) % menuItems.length);
      return true;
    }
    if (key === "Enter" || key === "Tab") {
      const selectedItem = menuItems[highlightedMenuIndex >= 0 ? highlightedMenuIndex : 0];
      if (selectedItem) {
        insertComposerMenuItem(selectedItem);
      }
      return true;
    }
    return false;
  };
  const selectProviderMenuItem = (providerId: ProviderId) => {
    selectProvider(providerId, state, dispatch);
    setProviderMenuOpen(false);
  };
  const modelPicker = intelligenceCollapse.hideControl ? null : h(
    "div",
    {
      className: "model-picker-root relative min-w-0",
      ref: (node: HTMLDivElement | null) => footerCollapse.setItemRef("intelligence", node),
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
          `model-picker ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} max-w-40 min-w-0 rounded-full`,
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
        h("span", { className: "model-label truncate whitespace-nowrap text-token-foreground" }, modelLabel),
        reasoningEffortLabel && !intelligenceCollapse.hideLabel
          ? h(
              "span",
              { className: "composer-footer__label--sm shrink-0 text-token-description-foreground" },
              reasoningEffortLabel,
            )
          : null,
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
      ? "text-base"
      : "text-base [&_.ProseMirror]:leading-5",
    minHeight: isSingleLineComposer ? "1.25rem" : "2.75rem",
    singleLine: isSingleLineComposer,
    value: state.input,
    ariaLabel: state.context?.copy.promptPlaceholder ?? "",
    placeholder: state.context?.copy.promptPlaceholder ?? "",
    onAutocompleteChange: updateComposerAutocomplete,
    onAutocompleteKeyDown: handleComposerAutocompleteKey,
    onTextChange: (input: string) => dispatch({ type: "setInput", input }),
    onSubmit: submit,
    onTriggerToken: (token: "@" | "$") => {
      setMenuKind(token === "@" ? "mention" : "skill");
      setMenuQuery("");
      setMenuIndex(0);
    },
  });
  const leftControls = h(
    "div",
    { className: "codex-left-rail flex min-w-0 items-center gap-[5px]" },
    h(AddContextDropdown, {
      isOpen: addContextMenuOpen,
      isPickingFiles,
      onOpenChange: setAddContextMenuOpen,
      onChoose: insertComposerMenuItem,
      onPickFiles: () => void pickLocalFiles(),
      state,
    }),
  );
  const secondaryControls = h(
    "div",
    { className: "codex-secondary-controls flex min-w-0 items-center gap-1", ref: footerCollapse.setContainerRef },
    modelPicker,
  );
  const actionCluster = h(
    "div",
    { className: "codex-action-cluster flex shrink-0 items-center gap-2" },
    showStart
      ? h(
          "button",
          {
            className: `codex-action codex-start ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} rounded-full`,
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
        className:
          `codex-action codex-mic ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full`,
        type: "button",
        disabled: true,
        "aria-label": state.context?.copy.voiceInput ?? "",
      },
      micIcon(),
    ),
    h(
      "button",
      {
        className:
          `codex-action send-button ${CODEX_SUBMIT_BUTTON}${canSend ? "" : " cursor-default opacity-50"}`,
        type: "button",
        disabled: !canSend,
        "aria-label": state.context?.copy.send ?? "Send",
        onClick: submit,
      },
      sendIcon("icon-sm text-token-dropdown-background"),
    ),
  );
  const singleLineRightControls = h(
    "div",
    { className: "flex min-w-0 shrink-0 items-center justify-end gap-2" },
    secondaryControls,
    actionCluster,
  );
  const composerInputWrapper = h(
    "div",
    {
      key: "composer-input",
      ref: isSingleLineComposer ? composerLayout.inputMeasureRef : undefined,
      className: isSingleLineComposer
        ? "min-w-0"
        : "mb-1 flex-grow overflow-y-auto px-3",
    },
    composerInput,
  );
  const composerControlsContent = isSingleLineComposer
    ? h(
        "div",
        {
          className:
            "composer-footer composer-footer-single-line grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2 px-2 py-1",
        },
        leftControls,
        composerInputWrapper,
        singleLineRightControls,
      )
    : h(
        "div",
        { className: "contents" },
        h("div", { className: "codex-attachment-tray px-2 py-1.5", "aria-hidden": true }),
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
            h("div", { className: "flex min-w-0 flex-1 justify-end" }, secondaryControls),
            actionCluster,
          ),
        ),
      );
  const composerControls = h(
    "div",
    { className: "codex-composer-inner relative z-10 flex min-h-0 flex-1 flex-col" },
    composerControlsContent,
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
                  highlightedIndex: highlightedMenuIndex,
                  items: menuItems,
                  onChoose: insertComposerMenuItem,
                  onHighlight: setMenuIndex,
                })
              : null,
            h(
              "div",
              {
                className:
                  "codex-composer-surface relative flex flex-col bg-token-input-background/90 backdrop-blur-lg electron:ring electron:ring-black/10 electron:shadow-[0_4px_16px_0_rgba(0,0,0,0.05)] electron:dark:bg-token-dropdown-background " +
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
  highlightedIndex,
  items,
  onChoose,
  onHighlight,
}: {
  highlightedIndex: number;
  items: ComposerMenuItem[];
  onChoose: (item: ComposerMenuItem) => void;
  onHighlight: (index: number) => void;
}) {
  return h(
    "div",
    { className: "codex-top-tray-shell absolute z-20" },
    h(
      "div",
      { className: "codex-top-tray-panel", "cmdk-root": "", "data-cmdk-root": true },
      h(
        "div",
        { className: "codex-top-tray-list", "cmdk-list": "", "data-cmdk-list": true },
        items.map((item, index) =>
          h(
            "button",
            {
              key: item.id,
              className: "codex-top-tray-item",
              type: "button",
              "aria-selected": index === highlightedIndex ? "true" : undefined,
              "cmdk-item": "",
              "data-selected": index === highlightedIndex ? "true" : undefined,
              "data-list-navigation-item": true,
              onMouseEnter: () => onHighlight(index),
              onMouseDown: (event: React.MouseEvent<HTMLButtonElement>) => event.preventDefault(),
              onClick: () => onChoose(item),
            },
            h("span", { className: "codex-top-tray-icon icon-xs shrink-0", "aria-hidden": true }, item.icon),
            h(
              "span",
              { className: "codex-top-tray-copy flex w-full min-w-0 items-center gap-2" },
              h("span", { className: "codex-top-tray-label truncate" }, item.label),
              h("span", { className: "codex-top-tray-detail flex-1 truncate text-sm text-token-description-foreground" }, item.detail),
            ),
          ),
        ),
      ),
    ),
  );
}

function AddContextDropdown({
  isOpen,
  isPickingFiles,
  onChoose,
  onOpenChange,
  onPickFiles,
  state,
}: {
  isOpen: boolean;
  isPickingFiles: boolean;
  onChoose: (item: ComposerMenuItem) => void;
  onOpenChange: (isOpen: boolean) => void;
  onPickFiles: () => void;
  state: SessionState;
}) {
  const copy = state.context?.copy;
  const mentionItems = composerMenuItems("mention", state, "");
  const workspaceItem = mentionItems.find((item) => item.id === "workspace") ?? null;
  const skillItems = composerMenuItems("skill", state, "");
  const chooseItem = (item: ComposerMenuItem) => {
    onChoose(item);
    onOpenChange(false);
  };
  return h(
    "div",
    {
      className: "add-context-root relative inline-flex",
      onBlur: (event: React.FocusEvent<HTMLDivElement>) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
          onOpenChange(false);
        }
      },
    },
    h(
      "button",
      {
        className:
          `codex-tool codex-tool-plus ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER_SM} ${CODEX_BUTTON_UNIFORM} rounded-full`,
        type: "button",
        "aria-label": copy?.attachFile ?? "Attach file",
        "aria-haspopup": "menu",
        "aria-expanded": isOpen,
        "data-state": isOpen ? "open" : "closed",
        onClick: () => onOpenChange(!isOpen),
        onKeyDown: (event: React.KeyboardEvent<HTMLButtonElement>) => {
          if (event.key === "ArrowDown") {
            event.preventDefault();
            onOpenChange(true);
          }
          if (event.key === "Escape") {
            event.preventDefault();
            onOpenChange(false);
          }
        },
      },
      plusIcon(),
    ),
    isOpen
      ? h(
          "div",
          {
            className:
              "add-context-dropdown _content_1hiti_1 no-drag bg-token-dropdown-background/90 text-token-foreground ring-token-border z-50 m-px flex select-none flex-col rounded-xl ring-[0.5px] px-1 py-1 shadow-xl-spread backdrop-blur-sm",
            role: "menu",
            "aria-label": copy?.attachFile ?? "Attach file",
          },
          h(AddContextMenuItem, {
            disabled: isPickingFiles,
            icon: paperclipIcon("icon-xs"),
            label: copy?.attachFile ?? "Attach file",
            onSelect: onPickFiles,
          }),
          workspaceItem
            ? h(AddContextMenuItem, {
                icon: atIcon(),
                label: copy?.autoContext ?? "Context",
                detail: workspaceItem.detail,
                onSelect: () => chooseItem(workspaceItem),
              })
            : null,
          h("div", { className: "add-context-separator", role: "separator" }),
          skillItems.map((item) =>
            h(AddContextMenuItem, {
              key: item.id,
              icon: skillIcon(),
              label: item.label,
              detail: item.detail,
              onSelect: () => chooseItem(item),
            })
          ),
        )
      : null,
  );
}

function AddContextMenuItem({
  detail,
  disabled = false,
  icon,
  label,
  onSelect,
}: {
  detail?: string;
  disabled?: boolean;
  icon: React.ReactNode;
  label: string;
  onSelect: () => void;
}) {
  return h(
    "button",
    {
      className: "add-context-item no-drag text-token-foreground outline-hidden rounded-lg px-[var(--padding-row-x)] py-[var(--padding-row-y)] text-sm",
      disabled,
      type: "button",
      role: "menuitem",
      onMouseDown: (event: React.MouseEvent<HTMLButtonElement>) => event.preventDefault(),
      onClick: disabled ? undefined : onSelect,
    },
    h("span", { className: "add-context-item-icon icon-xs shrink-0", "aria-hidden": true }, icon),
    h(
      "span",
      { className: "add-context-item-copy flex min-w-0 flex-1 items-center gap-2" },
      h("span", { className: "add-context-item-label min-w-0 truncate" }, label),
      detail
        ? h("span", { className: "add-context-item-detail min-w-0 flex-1 truncate text-token-description-foreground" }, detail)
        : null,
    ),
  );
}

type ComposerMenuItem = {
  detail: string;
  icon: string;
  id: string;
  label: string;
  mention: PromptMention;
};

function composerMenuItems(kind: Exclude<ComposerMenuKind, null>, state: SessionState, query: string): ComposerMenuItem[] {
  const copy = state.context?.copy;
  const items = kind === "mention"
    ? [
        state.context?.workingDirectory
          ? {
              id: "workspace",
              icon: "@",
              label: copy?.mentionCurrentWorkspace ?? "Current workspace",
              detail: basename(state.context.workingDirectory),
              mention: {
                kind: "at",
                label: basename(state.context.workingDirectory),
                name: basename(state.context.workingDirectory),
                path: state.context.workingDirectory,
                fsPath: state.context.workingDirectory,
              },
            }
          : null,
        ...state.providers.map((provider) => ({
          id: provider.id,
          icon: providerBadgeLabel(provider),
          label: provider.displayName,
          detail: provider.executableName,
          mention: {
            kind: "agent" as const,
            label: provider.displayName,
            name: provider.id,
            displayName: provider.displayName,
            path: `provider://${provider.id}`,
            description: provider.executableName,
          },
        })),
      ].filter((item): item is ComposerMenuItem => Boolean(item))
    : [
        {
          id: "plan",
          icon: "$",
          label: copy?.skillPlan ?? "Plan",
          detail: "$plan",
          mention: {
            kind: "skill" as const,
            label: "Plan",
            name: "plan",
            displayName: "Plan",
            path: "skill://plan",
          },
        },
        {
          id: "review",
          icon: "$",
          label: copy?.skillCodeReview ?? "Code review",
          detail: "$codex-review",
          mention: {
            kind: "skill" as const,
            label: "Code review",
            name: "codex-review",
            displayName: "Code review",
            path: "skill://codex-review",
          },
        },
        {
          id: "research",
          icon: "$",
          label: copy?.skillResearch ?? "Research",
          detail: "$research",
          mention: {
            kind: "skill" as const,
            label: "Research",
            name: "research",
            displayName: "Research",
            path: "skill://research",
          },
        },
      ];
  return filterComposerMenuItems(items, query);
}

function filterComposerMenuItems(items: ComposerMenuItem[], query: string): ComposerMenuItem[] {
  const normalizedQuery = query.trim().toLowerCase();
  if (!normalizedQuery) {
    return items;
  }
  return items.filter((item) => {
    const haystack = `${item.label} ${item.detail} ${item.mention.name}`.toLowerCase();
    return haystack.includes(normalizedQuery);
  });
}

function basename(path: string): string {
  const segments = path.split("/").filter(Boolean);
  return segments[segments.length - 1] ?? path;
}

function sendIcon(className = "icon-sm") {
  return h(
    "svg",
    { className, width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
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

function paperclipIcon(className = "icon-sm") {
  return h(
    "svg",
    { className, width: "21", height: "21", viewBox: "0 0 21 21", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M4.43945 12.8041V7.68261C4.43945 7.30642 4.74446 7.00141 5.12066 7.00141C5.49685 7.00141 5.80186 7.30642 5.80186 7.68261V12.8041C5.80186 15.2565 7.78984 17.2445 10.2422 17.2445C12.6945 17.2445 14.6825 15.2565 14.6825 12.8041V5.9751C14.6823 4.46587 13.4589 3.24247 11.9497 3.24229C10.4403 3.24229 9.21606 4.46576 9.21588 5.9751V12.8041C9.21588 13.3708 9.67553 13.8304 10.2422 13.8304C10.8088 13.8304 11.2685 13.3708 11.2685 12.8041V7.68261C11.2685 7.30642 11.5735 7.00141 11.9497 7.00141C12.3257 7.00159 12.6309 7.30653 12.6309 7.68261V12.8041C12.6309 14.1232 11.5612 15.1929 10.2422 15.1929C8.92314 15.1929 7.85347 14.1232 7.85347 12.8041V5.9751C7.85365 3.71337 9.68791 1.87988 11.9497 1.87988C14.2113 1.88006 16.0447 3.71348 16.0449 5.9751V12.8041C16.0449 16.0089 13.4469 18.6069 10.2422 18.6069C7.03745 18.6069 4.43945 16.0089 4.43945 12.8041Z",
      fill: "currentColor",
    }),
  );
}

function atIcon() {
  return h("span", { className: "add-context-glyph", "aria-hidden": true }, "@");
}

function skillIcon() {
  return h("span", { className: "add-context-glyph", "aria-hidden": true }, "$");
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

function applyCodexDocumentMetadata() {
  const root = document.documentElement;
  root.dataset.codexWindowType = "electron";
  root.dataset.windowType = "electron";
  root.dataset.codexOs = codexOs();
  if (document.body) {
    document.body.dataset.codexWindowType = "electron";
  }
}

function codexOs(): string {
  const maybeNavigator = navigator as Navigator & {
    userAgentData?: { platform?: string };
  };
  const platform = (
    maybeNavigator.userAgentData?.platform ??
    maybeNavigator.platform ??
    maybeNavigator.userAgent
  ).toLowerCase();
  if (platform.includes("win")) {
    return "win32";
  }
  if (platform.includes("mac") || platform.includes("darwin")) {
    return "darwin";
  }
  if (platform.includes("linux")) {
    return "linux";
  }
  return "unknown";
}

const root = document.getElementById("root");
if (root) {
  applyCodexDocumentMetadata();
  createRoot(root).render(h(App));
}
