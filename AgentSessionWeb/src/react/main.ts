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
import { promptTextWithPlanMode } from "../shared/promptModes";
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
import type {
  AgentSessionAttachment,
  AgentSessionCopy,
  AgentSessionRateLimitRow,
  ProviderId,
} from "../shared/types";
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
  dataUrl?: string;
  fsPath?: string;
  isImage?: boolean;
  label?: string;
  mimeType?: string;
  path: string;
};

type ComposerAttachment = AgentSessionAttachment;

function useMeasuredComposerLayout(input: string, hasVisibleAttachments: boolean) {
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
      hasVisibleAttachments,
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
  const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
  const canSend = state.status === "running" && (state.input.length > 0 || attachments.length > 0);
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
  const [isPlanMode, setIsPlanMode] = useState(false);
  const composerLayout = useMeasuredComposerLayout(state.input, attachments.length > 0);
  const isSingleLineComposer = composerLayout.isSingleLine;
  const menuItems = menuKind ? composerMenuItems(menuKind, state, menuQuery) : [];
  const highlightedMenuIndex = menuItems.length === 0 ? -1 : Math.min(menuIndex, menuItems.length - 1);
  const submit = () => {
    if (!canSend) {
      return;
    }
    setMenuKind(null);
    setMenuQuery("");
    setProviderMenuOpen(false);
    setAddContextMenuOpen(false);
    const providerInput = promptTextWithPlanMode(state.input, isPlanMode);
    const text = promptTextWithAttachments(providerInput, attachments);
    void sendInput(state, dispatch, {
      attachments,
      clearInput: state.input,
      displayText: state.input,
      text,
    }).then((didSend) => {
      if (didSend) {
        setAttachments([]);
      }
    });
  };
  const insertComposerMenuItem = (item: ComposerMenuItem) => {
    editorRef.current?.insertMention(item.mention);
    setMenuKind(null);
    setMenuQuery("");
    setMenuIndex(0);
    setAddContextMenuOpen(false);
  };
  const openSkillMenu = (query = "") => {
    setMenuKind("skill");
    setMenuQuery(query);
    setMenuIndex(0);
    setProviderMenuOpen(false);
    setAddContextMenuOpen(false);
    editorRef.current?.focus();
  };
  const insertSkillMenuItem = (id: string) => {
    const item = composerMenuItems("skill", state, "").find((item) => item.id === id);
    if (item) {
      insertComposerMenuItem(item);
    }
    editorRef.current?.focus();
  };
  const togglePlanMode = () => {
    setIsPlanMode((value) => !value);
    setAddContextMenuOpen(false);
    editorRef.current?.focus();
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
      const nextAttachments = (result.files ?? [])
        .filter((file) => file.path.trim().length > 0)
        .map((file): ComposerAttachment => {
          const label = file.label && file.label.trim().length > 0 ? file.label : basename(file.path);
          return {
            dataUrl: file.dataUrl,
            fsPath: file.fsPath ?? file.path,
            id: `${file.path}-${Date.now()}-${Math.random().toString(36).slice(2)}`,
            kind: file.isImage || file.dataUrl?.startsWith("data:image/") ? "image" : "file",
            label,
            mimeType: file.mimeType,
            path: file.path,
          };
        });
      setAttachments((existing) => dedupeAttachments([...existing, ...nextAttachments]));
      editorRef.current?.focus();
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
      onTogglePlanMode: togglePlanMode,
      isPlanMode,
      state,
    }),
    h(ComposerFooterButton, {
      ariaLabel: state.context?.copy.browseWeb ?? "Browse web",
      icon: globeIcon(),
      onClick: () => insertSkillMenuItem("research"),
    }),
    h(ComposerFooterButton, {
      ariaLabel: state.context?.copy.skillPlan ?? "Plan",
      icon: sparkleIcon(),
      isSelected: isPlanMode,
      onClick: togglePlanMode,
    }),
    isPlanMode
      ? h(ComposerModeIndicator, {
          icon: sparkleIcon("icon-xs"),
          label: state.context?.copy.skillPlan ?? "Plan",
          onClear: () => setIsPlanMode(false),
        })
      : null,
    h(ComposerFooterButton, {
      ariaLabel: state.context?.copy.tools ?? "Tools",
      icon: toolsIcon(),
      onClick: () => openSkillMenu(),
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
        attachments.length > 0
          ? h(ComposerAttachmentTray, {
              attachments,
              copy: state.context?.copy,
              onRemove: (id: string) => {
                setAttachments((current) => current.filter((attachment) => attachment.id !== id));
              },
            })
          : null,
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
    case "user": {
      const attachments = entry.attachments ?? [];
      const hasText = entry.text.trim().length > 0;
      return h(
        "div",
        { className: "codex-user-turn group flex w-full flex-col items-end justify-end gap-1" },
        attachments.length > 0
          ? h(ComposerAttachmentTray, {
              attachments,
              className: "codex-user-attachment-tray",
            })
          : null,
        hasText
          ? h(
              "div",
              {
                className:
                  "codex-user-bubble bg-token-foreground/5 max-w-[77%] min-w-0 overflow-hidden break-words rounded-2xl px-3 py-2 [&_.contain-inline-size]:[contain:initial]",
              },
              h("div", {
                className: "text-size-chat mb-px",
                dangerouslySetInnerHTML: { __html: renderPlainTextHTML(entry.text) },
              }),
            )
          : null,
      );
    }
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

function ComposerAttachmentTray({
  attachments,
  className,
  copy,
  onRemove,
}: {
  attachments: ComposerAttachment[];
  className?: string;
  copy?: AgentSessionCopy;
  onRemove?: (id: string) => void;
}) {
  return h(
    "div",
    { className: `codex-attachment-tray flex gap-1.5 overflow-x-auto px-3 pt-2 pb-1${className ? ` ${className}` : ""}` },
    attachments.map((attachment) =>
      h(ComposerAttachmentCard, {
        attachment,
        copy,
        key: attachment.id,
        onRemove,
      }),
    ),
  );
}

function ComposerAttachmentCard({
  attachment,
  copy,
  onRemove,
}: {
  attachment: ComposerAttachment;
  copy?: AgentSessionCopy;
  onRemove?: (id: string) => void;
}) {
  const removeLabel = `${copy?.removeAttachment ?? "Remove attachment"} ${attachment.label}`;
  const removeButton = onRemove
    ? h(
        "button",
        {
          className: "composer-attachment-remove",
          type: "button",
          "aria-label": removeLabel,
          onClick: () => onRemove(attachment.id),
          onMouseDown: (event: React.MouseEvent<HTMLButtonElement>) => event.preventDefault(),
        },
        xIcon("icon-2xs"),
      )
    : null;
  if (attachment.kind === "image" && attachment.dataUrl) {
    return h(
      "div",
      {
        className: "composer-attachment-image",
        title: attachment.label,
      },
      h("img", { alt: "", "aria-hidden": true, src: attachment.dataUrl }),
      removeButton,
    );
  }
  return h(
    "div",
    {
      className: "composer-attachment-file",
      title: attachment.path,
    },
    h("span", { className: "composer-attachment-file-icon", "aria-hidden": true }, paperclipIcon("icon-xs")),
    h("span", { className: "composer-attachment-file-label" }, attachment.label),
    removeButton,
  );
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

function ComposerFooterButton({
  ariaLabel,
  icon,
  isSelected = false,
  onClick,
}: {
  ariaLabel: string;
  icon: React.ReactNode;
  isSelected?: boolean;
  onClick: () => void;
}) {
  return h(
    "button",
    {
      className:
        `codex-tool ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full`,
      type: "button",
      "aria-label": ariaLabel,
      "aria-pressed": isSelected,
      "data-state": isSelected ? "open" : "closed",
      onClick,
    },
    icon,
  );
}

function ComposerModeIndicator({
  icon,
  label,
  onClear,
}: {
  icon: React.ReactNode;
  label: string;
  onClear: () => void;
}) {
  return h(
    "div",
    { className: "composer-mode-indicator flex min-w-0 items-center gap-1" },
    h("div", { className: "composer-mode-divider", "aria-hidden": true }),
    h(
      "button",
      {
        className:
          `composer-mode-button ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} rounded-full`,
        type: "button",
        "aria-label": label,
        onClick: onClear,
      },
      h("span", { className: "composer-mode-icon", "aria-hidden": true }, icon),
      h("span", { className: "composer-mode-label" }, label),
    ),
  );
}

function AddContextDropdown({
  isOpen,
  isPickingFiles,
  isPlanMode,
  onChoose,
  onOpenChange,
  onPickFiles,
  onTogglePlanMode,
  state,
}: {
  isOpen: boolean;
  isPickingFiles: boolean;
  isPlanMode: boolean;
  onChoose: (item: ComposerMenuItem) => void;
  onOpenChange: (isOpen: boolean) => void;
  onPickFiles: () => void;
  onTogglePlanMode: () => void;
  state: SessionState;
}) {
  const copy = state.context?.copy;
  const addFilesAndMoreLabel = copy?.addFilesAndMore ?? "Add files and more";
  const addPhotosAndFilesLabel = copy?.addPhotosAndFiles ?? "Add photos & files";
  const mentionItems = composerMenuItems("mention", state, "");
  const workspaceItem = mentionItems.find((item) => item.id === "workspace") ?? null;
  const skillItems = composerMenuItems("skill", state, "");
  const planItem = skillItems.find((item) => item.id === "plan") ?? null;
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
          `codex-tool codex-tool-plus ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full`,
        type: "button",
        "aria-label": addFilesAndMoreLabel,
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
            "aria-label": addFilesAndMoreLabel,
          },
          h(AddContextMenuItem, {
            disabled: isPickingFiles,
            icon: paperclipIcon("icon-xs"),
            label: addPhotosAndFilesLabel,
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
          workspaceItem || planItem ? h("div", { className: "add-context-separator", role: "separator" }) : null,
          planItem
            ? h(AddContextMenuSwitchItem, {
                checked: isPlanMode,
                icon: sparkleIcon(),
                label: copy?.planMode ?? "Plan mode",
                onSelect: onTogglePlanMode,
              })
            : null,
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

function AddContextMenuSwitchItem({
  checked,
  icon,
  label,
  onSelect,
}: {
  checked: boolean;
  icon: React.ReactNode;
  label: string;
  onSelect: () => void;
}) {
  return h(
    "button",
    {
      className: "add-context-item no-drag text-token-foreground outline-hidden rounded-lg px-[var(--padding-row-x)] py-[var(--padding-row-y)] text-sm",
      type: "button",
      role: "menuitemcheckbox",
      "aria-checked": checked,
      onMouseDown: (event: React.MouseEvent<HTMLButtonElement>) => event.preventDefault(),
      onClick: onSelect,
    },
    h("span", { className: "add-context-item-icon icon-xs shrink-0", "aria-hidden": true }, icon),
    h("span", { className: "add-context-item-label min-w-0 flex-1 truncate" }, label),
    h("span", { className: "add-context-switch", "data-checked": checked ? "true" : "false", "aria-hidden": true }),
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

function dedupeAttachments(attachments: ComposerAttachment[]): ComposerAttachment[] {
  const seen = new Set<string>();
  return attachments.filter((attachment) => {
    const key = `${attachment.kind}:${attachment.path}`;
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

function promptTextWithAttachments(input: string, attachments: ComposerAttachment[]): string {
  const attachmentText = attachments
    .map((attachment) => `[${escapeMarkdownLabel(attachment.label)}](${escapeMarkdownDestination(attachment.path)})`)
    .join(" ");
  if (!attachmentText) {
    return input;
  }
  return input.trim().length > 0 ? `${attachmentText}\n\n${input}` : attachmentText;
}

function escapeMarkdownLabel(label: string): string {
  return label.replace(/([\\\]])/g, "\\$1");
}

function escapeMarkdownDestination(destination: string): string {
  return destination.replace(/([\\()])/g, "\\$1");
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

function xIcon(className = "icon-sm") {
  return h(
    "svg",
    { className, width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M5.96967 5.96967C6.26256 5.67678 6.73744 5.67678 7.03033 5.96967L10 8.93934L12.9697 5.96967C13.2626 5.67678 13.7374 5.67678 14.0303 5.96967C14.3232 6.26256 14.3232 6.73744 14.0303 7.03033L11.0607 10L14.0303 12.9697C14.3232 13.2626 14.3232 13.7374 14.0303 14.0303C13.7374 14.3232 13.2626 14.3232 12.9697 14.0303L10 11.0607L7.03033 14.0303C6.73744 14.3232 6.26256 14.3232 5.96967 14.0303C5.67678 13.7374 5.67678 13.2626 5.96967 12.9697L8.93934 10L5.96967 7.03033C5.67678 6.73744 5.67678 6.26256 5.96967 5.96967Z",
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

function globeIcon() {
  return h(
    "svg",
    { className: "icon-sm", width: "20", height: "20", viewBox: "0 0 20 20", fill: "currentColor", "aria-hidden": true },
    h("path", {
      d: "M10 2.125C14.3492 2.125 17.875 5.65076 17.875 10C17.875 14.3492 14.3492 17.875 10 17.875C5.65076 17.875 2.125 14.3492 2.125 10C2.125 5.65076 5.65076 2.125 10 2.125ZM7.88672 10.625C7.94334 12.3161 8.22547 13.8134 8.63965 14.9053C8.87263 15.5194 9.1351 15.9733 9.39453 16.2627C9.65437 16.5524 9.86039 16.625 10 16.625C10.1396 16.625 10.3456 16.5524 10.6055 16.2627C10.8649 15.9733 11.1274 15.5194 11.3604 14.9053C11.7745 13.8134 12.0567 12.3161 12.1133 10.625H7.88672ZM3.40527 10.625C3.65313 13.2734 5.45957 15.4667 7.89844 16.2822C7.7409 15.997 7.5977 15.6834 7.4707 15.3486C6.99415 14.0923 6.69362 12.439 6.63672 10.625H3.40527ZM13.3633 10.625C13.3064 12.439 13.0059 14.0923 12.5293 15.3486C12.4022 15.6836 12.2582 15.9969 12.1006 16.2822C14.5399 15.467 16.3468 13.2737 16.5947 10.625H13.3633ZM12.1006 3.7168C12.2584 4.00235 12.4021 4.31613 12.5293 4.65137C13.0059 5.90775 13.3064 7.56102 13.3633 9.375H16.5947C16.3468 6.72615 14.54 4.53199 12.1006 3.7168ZM10 3.375C9.86039 3.375 9.65437 3.44756 9.39453 3.7373C9.1351 4.02672 8.87263 4.48057 8.63965 5.09473C8.22547 6.18664 7.94334 7.68388 7.88672 9.375H12.1133C12.0567 7.68388 11.7745 6.18664 11.3604 5.09473C11.1274 4.48057 10.8649 4.02672 10.6055 3.7373C10.3456 3.44756 10.1396 3.375 10 3.375ZM7.89844 3.7168C5.45942 4.53222 3.65314 6.72647 3.40527 9.375H6.63672C6.69362 7.56102 6.99415 5.90775 7.4707 4.65137C7.59781 4.31629 7.74073 4.00224 7.89844 3.7168Z",
    }),
  );
}

function sparkleIcon(className = "icon-sm") {
  return h(
    "svg",
    { className, width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      fillRule: "evenodd",
      clipRule: "evenodd",
      d: "M5.69336 11.0557C7.05891 11.1944 8.12484 12.3479 8.125 13.75L8.11035 14.0273C7.97144 15.3928 6.81814 16.459 5.41602 16.459L5.13965 16.4443C3.86514 16.3149 2.85128 15.3018 2.72168 14.0273L2.70801 13.75C2.70818 12.2546 3.92061 11.0423 5.41602 11.042L5.69336 11.0557ZM5.41602 12.3721C4.65515 12.3724 4.03826 12.9891 4.03809 13.75C4.03826 14.5109 4.65515 15.1286 5.41602 15.1289C6.17714 15.1289 6.79475 14.5111 6.79492 13.75C6.79475 12.9889 6.17714 12.3721 5.41602 12.3721Z",
      fill: "currentColor",
    }),
    h("path", {
      d: "M16.8008 13.0986C17.1036 13.1608 17.3311 13.4288 17.3311 13.75C17.3311 14.0712 17.1036 14.3392 16.8008 14.4014L16.666 14.415H10.833C10.4659 14.4149 10.168 14.1172 10.168 13.75C10.168 13.3828 10.4659 13.0851 10.833 13.085H16.666L16.8008 13.0986Z",
      fill: "currentColor",
    }),
    h("path", {
      d: "M16.8008 5.59863C17.1036 5.66081 17.3311 5.92879 17.3311 6.25C17.3311 6.57121 17.1036 6.83919 16.8008 6.90137L16.666 6.91504H10.833C10.4659 6.91491 10.168 6.61719 10.168 6.25C10.168 5.88281 10.4659 5.58509 10.833 5.58496H16.666L16.8008 5.59863Z",
      fill: "currentColor",
    }),
    h("path", {
      d: "M7.13311 3.76578C7.35346 3.47216 7.771 3.4128 8.06475 3.63297C8.35843 3.85336 8.41789 4.27084 8.19757 4.56461L5.19757 8.56461C5.0819 8.71866 4.90439 8.81462 4.71221 8.82828C4.5201 8.84178 4.33083 8.77209 4.19464 8.6359L2.69464 7.1359C2.43512 6.87623 2.43512 6.45415 2.69464 6.19449C2.95429 5.93484 3.37633 5.93493 3.63604 6.19449L4.59307 7.15152L7.13311 3.76578Z",
      fill: "currentColor",
    }),
  );
}

function toolsIcon() {
  return h(
    "svg",
    { className: "icon-sm", width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M12.42 3.58l1.25 1.25M4.75 15.25l5.82-5.82M10.57 9.43l4.18 4.18c.43.43.43 1.13 0 1.56l-.58.58c-.43.43-1.13.43-1.56 0L8.43 11.57M11.08 4.92l4-2l2 2l-2 4L6.33 17.67H2.5v-3.84l8.58-8.91Z",
      stroke: "currentColor",
      strokeWidth: "1.35",
      strokeLinecap: "round",
      strokeLinejoin: "round",
    }),
  );
}

function atIcon() {
  return h("span", { className: "add-context-glyph", "aria-hidden": true }, "@");
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
