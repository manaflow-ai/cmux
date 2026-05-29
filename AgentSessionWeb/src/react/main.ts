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
import { promptTextWithAttachments } from "../shared/promptAttachments";
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
  canStopProvider,
  loadInitialData,
  messageForError,
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
type ComposerPermissionMode = "default" | "auto-review" | "full-access" | "custom";

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
  const canStop = canStopProvider(state);
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
  const [permissionsMenuOpen, setPermissionsMenuOpen] = useState(false);
  const [permissionMode, setPermissionMode] = useState<ComposerPermissionMode>("default");
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
    setPermissionsMenuOpen(false);
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
    setPermissionsMenuOpen(false);
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
    setPermissionsMenuOpen(false);
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
        onClick: () => {
          if (!canSelect) {
            return;
          }
          setAddContextMenuOpen(false);
          setPermissionsMenuOpen(false);
          setProviderMenuOpen((open) => !open);
        },
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
  const permissionsControl = (hideLabel = false) =>
    h(PermissionsDropdown, {
      copy: state.context?.copy,
      hideLabel,
      isEnabled: true,
      isOpen: permissionsMenuOpen,
      mode: permissionMode,
      onModeChange: setPermissionMode,
      onOpenChange: (isOpen: boolean) => {
        setPermissionsMenuOpen(isOpen);
        if (isOpen) {
          setAddContextMenuOpen(false);
          setProviderMenuOpen(false);
          setMenuKind(null);
        }
      },
    });
  const leftControls = h(
    "div",
    { className: "codex-left-rail flex min-w-0 items-center gap-[5px]" },
    h(AddContextDropdown, {
      isOpen: addContextMenuOpen,
      isPickingFiles,
      onOpenChange: (isOpen: boolean) => {
        setAddContextMenuOpen(isOpen);
        if (isOpen) {
          setPermissionsMenuOpen(false);
          setProviderMenuOpen(false);
          setMenuKind(null);
        }
      },
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
    isSingleLineComposer ? null : permissionsControl(false),
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
    canStop
      ? h(
          "button",
          {
            className:
              `codex-action codex-stop ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${CODEX_BUTTON_COMPOSER} ${CODEX_BUTTON_UNIFORM} rounded-full`,
            type: "button",
            "aria-label": state.context?.copy.stop ?? "Stop",
            onClick: () => void stopProvider(state, dispatch),
          },
          stopIcon(),
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
    permissionsControl(true),
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
                  "codex-composer-surface relative flex flex-col bg-token-input-background/90 backdrop-blur-lg extension:border extension:border-token-border/50 electron:ring electron:ring-black/10 electron:shadow-[0_4px_16px_0_rgba(0,0,0,0.05)] electron:dark:bg-token-dropdown-background " +
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

function PermissionsDropdown({
  copy,
  hideLabel = false,
  isEnabled,
  isOpen,
  mode,
  onModeChange,
  onOpenChange,
}: {
  copy?: AgentSessionCopy;
  hideLabel?: boolean;
  isEnabled: boolean;
  isOpen: boolean;
  mode: ComposerPermissionMode;
  onModeChange: (mode: ComposerPermissionMode) => void;
  onOpenChange: (isOpen: boolean) => void;
}) {
  const triggerLabel = copy?.changePermissions ?? "Change permissions";
  const selectedLabel = permissionModeLabel(copy, mode);
  const options: ComposerPermissionMode[] = isEnabled ? ["default", "auto-review", "full-access", "custom"] : [];
  const triggerSizeClass = hideLabel ? CODEX_BUTTON_COMPOSER : CODEX_BUTTON_COMPOSER_SM;
  const selectMode = (nextMode: ComposerPermissionMode) => {
    onModeChange(nextMode);
    onOpenChange(false);
  };
  const effectiveIsOpen = isEnabled && isOpen;
  return h(
    "div",
    {
      className: "permissions-root relative inline-flex",
      onBlur: (event: React.FocusEvent<HTMLDivElement>) => {
        if (isEnabled && !event.currentTarget.contains(event.relatedTarget as Node | null)) {
          onOpenChange(false);
        }
      },
    },
    h(
      "button",
      {
        className:
          `permissions-trigger ${CODEX_BUTTON_BASE} ${CODEX_BUTTON_GHOST} ${triggerSizeClass} ${hideLabel ? CODEX_BUTTON_UNIFORM : "min-w-0"} rounded-full`,
        type: "button",
        "aria-label": triggerLabel,
        "aria-haspopup": isEnabled ? "menu" : undefined,
        "aria-expanded": isEnabled ? effectiveIsOpen : undefined,
        "aria-disabled": isEnabled ? undefined : true,
        "data-permission-mode": mode,
        "data-state": effectiveIsOpen ? "open" : "closed",
        disabled: !isEnabled,
        onClick: () => {
          if (isEnabled) {
            onOpenChange(!effectiveIsOpen);
          }
        },
        onKeyDown: (event: React.KeyboardEvent<HTMLButtonElement>) => {
          if (!isEnabled) {
            return;
          }
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
      permissionModeIcon(mode, "icon-xs shrink-0"),
      hideLabel
        ? null
        : h(
            "span",
            { className: "permissions-trigger-label composer-footer__label--xs max-w-40 truncate whitespace-nowrap text-left" },
            selectedLabel,
          ),
      isEnabled ? h("span", { className: "permissions-trigger-chevron icon-2xs shrink-0", "aria-hidden": true }, chevronIcon()) : null,
    ),
    effectiveIsOpen
      ? h(
          "div",
          {
            className:
              "permissions-dropdown _content_1hiti_1 no-drag bg-token-dropdown-background/90 text-token-foreground ring-token-border z-50 m-px flex select-none flex-col overflow-y-auto rounded-xl ring-[0.5px] px-1 py-1 shadow-xl-spread backdrop-blur-sm",
            role: "menu",
            "aria-label": triggerLabel,
          },
          options.map((option) =>
            h(PermissionsMenuItem, {
              isSelected: option === mode,
              key: option,
              label: permissionModeLabel(copy, option),
              mode: option,
              onSelect: () => selectMode(option),
            }),
          ),
        )
      : null,
  );
}

function PermissionsMenuItem({
  isSelected,
  label,
  mode,
  onSelect,
}: {
  isSelected: boolean;
  label: string;
  mode: ComposerPermissionMode;
  onSelect: () => void;
}) {
  return h(
    "button",
    {
      className: "permissions-item no-drag text-token-foreground outline-hidden rounded-lg px-[var(--padding-row-x)] py-[var(--padding-row-y)] text-sm",
      type: "button",
      role: "menuitemradio",
      "aria-checked": isSelected,
      "data-permission-mode": mode,
      "data-selected": isSelected ? "true" : undefined,
      onMouseDown: (event: React.MouseEvent<HTMLButtonElement>) => event.preventDefault(),
      onClick: onSelect,
    },
    h("span", { className: "permissions-item-icon icon-xs shrink-0", "aria-hidden": true }, permissionModeIcon(mode, "icon-xs shrink-0")),
    h("span", { className: "permissions-item-label min-w-0 flex-1 truncate" }, label),
    isSelected ? h("span", { className: "permissions-item-check icon-xs shrink-0", "aria-hidden": true }, checkIcon()) : null,
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

function permissionModeLabel(copy: AgentSessionCopy | undefined, mode: ComposerPermissionMode): string {
  switch (mode) {
    case "auto-review":
      return copy?.permissionsAutoReview ?? "Auto-review";
    case "full-access":
      return copy?.permissionsFullAccess ?? "Full access";
    case "custom":
      return copy?.permissionsCustom ?? "Custom (config.toml)";
    case "default":
      return copy?.permissionsDefault ?? "Default permissions";
  }
}

function permissionModeIcon(mode: ComposerPermissionMode, className = "icon-xs shrink-0") {
  switch (mode) {
    case "auto-review":
      return shieldWarningIcon(className);
    case "full-access":
      return shieldCodeIcon(className);
    case "custom":
      return settingsCogIcon(className);
    case "default":
      return permissionsDefaultIcon(className);
  }
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

function stopIcon() {
  return h(
    "svg",
    { width: "16", height: "16", viewBox: "0 0 16 16", fill: "none", "aria-hidden": true },
    h("rect", {
      x: "4.75",
      y: "4.75",
      width: "6.5",
      height: "6.5",
      rx: "1",
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

function permissionsDefaultIcon(className = "icon-sm") {
  return h(
    "svg",
    { className, width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      d: "M12.6683 4.16699C12.6683 3.84391 12.4065 3.58203 12.0834 3.58203C11.7603 3.58203 11.4984 3.84391 11.4984 4.16699V7.91699L11.4847 8.05078C11.4227 8.35375 11.1547 8.58203 10.8334 8.58203C10.4662 8.58203 10.1685 8.28411 10.1683 7.91699V3.75C10.1683 3.42691 9.90646 3.16504 9.58337 3.16504C9.26029 3.16504 8.99841 3.42691 8.99841 3.75V7.91699C8.99824 8.28411 8.70053 8.58203 8.33337 8.58203C7.96621 8.58203 7.66851 8.28411 7.66833 7.91699V5C7.66833 4.67691 7.40646 4.41504 7.08337 4.41504C6.76029 4.41504 6.49841 4.67691 6.49841 5V9.30371C6.53326 9.3429 6.56715 9.38359 6.59998 9.42578L8.02478 11.2588C8.25005 11.5486 8.19821 11.9659 7.90857 12.1914C7.6187 12.4169 7.20048 12.365 6.97498 12.0752L5.55017 10.2432C5.15812 9.7391 4.41813 9.73637 4.01501 10.1924C4.04396 10.426 4.11486 10.8323 4.25525 11.3486C4.44664 12.0525 4.75404 12.9113 5.21619 13.7383C6.14103 15.3931 7.62465 16.835 10.0004 16.835C12.8545 16.8348 15.1682 14.5211 15.1683 11.667V6.25C15.1683 5.92691 14.9065 5.66504 14.5834 5.66504C14.2603 5.66504 13.9984 5.92691 13.9984 6.25V9.16699C13.9982 9.53411 13.7005 9.83203 13.3334 9.83203C12.9662 9.83203 12.6685 9.53411 12.6683 9.16699V4.16699ZM13.9984 4.42578C14.1828 4.36671 14.3794 4.33496 14.5834 4.33496C15.641 4.33496 16.4984 5.19237 16.4984 6.25V11.667C16.4982 15.2557 13.589 18.1649 10.0004 18.165C6.95953 18.165 5.10939 16.2734 4.05505 14.3867C3.52774 13.4431 3.1843 12.4787 2.97205 11.6982C2.76447 10.9349 2.66834 10.2954 2.66833 10C2.66833 9.87959 2.70117 9.76148 2.76306 9.6582C3.28988 8.78018 4.26555 8.40372 5.16833 8.56152V5C5.16833 3.94237 6.02575 3.08496 7.08337 3.08496C7.31706 3.08496 7.54039 3.12845 7.74744 3.20508C7.98218 2.41297 8.7151 1.83496 9.58337 1.83496C10.1836 1.83496 10.7186 2.11176 11.0697 2.54395C11.3639 2.35978 11.7107 2.25195 12.0834 2.25195C13.141 2.25195 13.9984 3.10937 13.9984 4.16699V4.42578Z",
      fill: "currentColor",
    }),
  );
}

function shieldCodeIcon(className = "icon-sm") {
  return h(
    "svg",
    { className, width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      fillRule: "evenodd",
      clipRule: "evenodd",
      d: "M9.06543 1.95123C9.66107 1.69076 10.3389 1.69071 10.9346 1.95123L15.9346 4.13873C16.7832 4.51008 17.3311 5.34917 17.3311 6.27545V10.5528C17.3309 14.6017 14.0489 17.8847 10 17.8848C5.95108 17.8846 2.66813 14.6017 2.66797 10.5528V6.27545C2.66797 5.34924 3.21695 4.51012 4.06543 4.13873L9.06543 1.95123ZM10.4014 3.16998C10.1456 3.05814 9.85444 3.05819 9.59863 3.16998L4.59863 5.35748C4.23427 5.51708 3.99805 5.87764 3.99805 6.27545V10.5528C3.99821 13.8671 6.68563 16.5546 10 16.5547C13.3144 16.5546 16.0008 13.8671 16.001 10.5528V6.27545C16.001 5.87756 15.7658 5.51703 15.4014 5.35748L10.4014 3.16998Z",
      fill: "currentColor",
    }),
    h("path", {
      d: "M13.4678 11.4318L13.333 11.4182H10.833C10.466 11.4183 10.1682 11.7162 10.168 12.0832C10.168 12.4504 10.4659 12.7481 10.833 12.7482H13.333L13.4678 12.7346C13.7706 12.6724 13.9981 12.4044 13.9981 12.0832C13.9979 11.7621 13.7706 11.494 13.4678 11.4318Z",
      fill: "currentColor",
    }),
    h("path", {
      d: "M7.65336 12.426C7.46431 12.7406 7.05607 12.8424 6.74125 12.6535C6.42646 12.4646 6.32395 12.0563 6.51274 11.7414L7.55668 10.0002L6.51274 8.25899C6.32395 7.94412 6.42646 7.53583 6.74125 7.34688C7.05607 7.15799 7.46431 7.25975 7.65336 7.57442L8.90336 9.6584C9.0296 9.86893 9.0296 10.1315 8.90336 10.342L7.65336 12.426Z",
      fill: "currentColor",
    }),
  );
}

function shieldWarningIcon(className = "icon-sm") {
  return h(
    "svg",
    { className, width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      fillRule: "evenodd",
      clipRule: "evenodd",
      d: "M9.06543 1.95123C9.66107 1.69076 10.3389 1.69071 10.9346 1.95123L15.9346 4.13873C16.7832 4.51008 17.3311 5.34917 17.3311 6.27545V10.5528C17.3309 14.6017 14.0489 17.8847 10 17.8848C5.95108 17.8846 2.66813 14.6017 2.66797 10.5528V6.27545C2.66797 5.34924 3.21695 4.51012 4.06543 4.13873L9.06543 1.95123ZM10.4014 3.16998C10.1456 3.05814 9.85444 3.05819 9.59863 3.16998L4.59863 5.35748C4.23427 5.51708 3.99805 5.87764 3.99805 6.27545V10.5528C3.99821 13.8671 6.68563 16.5546 10 16.5547C13.3144 16.5546 16.0008 13.8671 16.001 10.5528V6.27545C16.001 5.87756 15.7658 5.51703 15.4014 5.35748L10.4014 3.16998Z",
      fill: "currentColor",
    }),
    h("path", {
      d: "M10.8883 13.1116C10.8883 13.6025 10.4903 14.0005 9.99936 14.0005C9.50844 14.0005 9.11047 13.6025 9.11047 13.1116C9.11047 12.6207 9.50844 12.2227 9.99936 12.2227C10.4903 12.2227 10.8883 12.6207 10.8883 13.1116Z",
      fill: "currentColor",
    }),
    h("path", {
      d: "M10.5169 10.8949L11.1135 7.31519C11.2283 6.62672 10.6974 6 9.99941 6C9.30145 6 8.77053 6.62672 8.88528 7.31519L9.4819 10.8949C9.52406 11.1479 9.74294 11.3333 9.99941 11.3333C10.2559 11.3333 10.4748 11.1479 10.5169 10.8949Z",
      fill: "currentColor",
    }),
  );
}

function settingsCogIcon(className = "icon-sm") {
  return h(
    "svg",
    { className, width: "20", height: "20", viewBox: "0 0 20 20", fill: "none", "aria-hidden": true },
    h("path", {
      fillRule: "evenodd",
      clipRule: "evenodd",
      d: "M9.99944 7.24939C11.5169 7.2495 12.7473 8.47995 12.7475 9.99744C12.7475 11.5151 11.517 12.7454 9.99944 12.7455C8.48176 12.7455 7.2514 11.5151 7.2514 9.99744C7.25155 8.47988 8.48186 7.24939 9.99944 7.24939ZM9.99944 8.57947C9.2164 8.57947 8.58163 9.21442 8.58148 9.99744C8.58148 10.7806 9.2163 11.4154 9.99944 11.4154C10.7825 11.4153 11.4174 10.7805 11.4174 9.99744C11.4173 9.21449 10.7824 8.57958 9.99944 8.57947Z",
      fill: "currentColor",
    }),
    h("path", {
      fillRule: "evenodd",
      clipRule: "evenodd",
      d: "M10.6391 1.67517C11.2939 1.67532 11.8991 2.02577 12.226 2.59314L13.2485 4.36755H15.2963C15.9505 4.36758 16.555 4.71709 16.8823 5.28357L17.5219 6.39001C17.8489 6.95668 17.8481 7.65542 17.5209 8.22205L16.4975 9.99451L17.5239 11.7689C17.8519 12.3357 17.8521 13.0347 17.5248 13.6019L16.8862 14.7084C16.559 15.2747 15.9543 15.6243 15.3002 15.6244H13.2514L12.2299 17.3988C11.9029 17.9663 11.297 18.3168 10.642 18.3168L9.3637 18.3158C8.71064 18.3155 8.10718 17.9678 7.77972 17.4027L6.74847 15.6234L4.69964 15.6244C4.04558 15.6242 3.44087 15.2747 3.1137 14.7084L2.47503 13.6019C2.14791 13.0349 2.14836 12.3366 2.47601 11.7699L3.50237 9.99548L2.47894 8.22205C2.15175 7.65533 2.15174 6.95673 2.47894 6.39001L3.11761 5.28259C3.44458 4.71663 4.04894 4.36813 4.70257 4.36755L6.75042 4.36658L7.77581 2.59119C8.10301 2.02476 8.7076 1.67527 9.36175 1.67517H10.6391ZM9.36273 3.00623C9.1835 3.00623 9.01679 3.10199 8.92718 3.2572L7.82659 5.16345C7.63652 5.49253 7.28473 5.69529 6.90472 5.69568L4.70355 5.69763C4.52451 5.69782 4.3585 5.79355 4.26898 5.94861L3.6303 7.05505C3.54091 7.2102 3.54077 7.40192 3.6303 7.55701L4.73089 9.46326C4.92108 9.7929 4.92135 10.1992 4.73089 10.5287L3.62737 12.4359C3.5378 12.591 3.53792 12.7817 3.62737 12.9369L4.26605 14.0433C4.35567 14.1982 4.52067 14.2932 4.69964 14.2933L6.90276 14.2943C7.28242 14.2946 7.63335 14.497 7.82366 14.8256L8.93011 16.7357C9.01984 16.8905 9.18578 16.9857 9.36468 16.9857H10.642C10.8213 16.9857 10.987 16.89 11.0766 16.7347L12.1752 14.8275C12.3653 14.4975 12.7182 14.2943 13.0991 14.2943H15.3002C15.4794 14.2942 15.6452 14.1985 15.7348 14.0433L16.3725 12.9379C16.4621 12.7826 16.4621 12.5911 16.3725 12.4359L15.27 10.5287C15.1032 10.2404 15.0808 9.89331 15.2055 9.59021L15.269 9.46326L16.3696 7.55701C16.4591 7.40189 16.459 7.21022 16.3696 7.05505L15.7309 5.94861C15.6412 5.79363 15.4754 5.69863 15.2963 5.69861L13.0951 5.69763L12.9535 5.68884C12.6751 5.65158 12.4217 5.50519 12.2504 5.28259L12.1723 5.16443L11.0737 3.2572C10.9841 3.10175 10.8175 3.00525 10.6381 3.00525L9.36273 3.00623Z",
      fill: "currentColor",
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
