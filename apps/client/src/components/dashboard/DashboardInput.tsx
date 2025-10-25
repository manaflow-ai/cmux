import LexicalEditor from "@/components/lexical/LexicalEditor";
import clsx from "clsx";
import {
  forwardRef,
  memo,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
} from "react";
import type { Id } from "@cmux/convex/dataModel";
import { isElectron } from "@/lib/electron";

export interface EditorApi {
  getContent: () => {
    text: string;
    images: Array<{
      src: string;
      fileName?: string;
      altText: string;
    }>;
  };
  clear: () => void;
  focus?: () => void;
  insertText?: (text: string) => void;
}

interface DashboardInputProps {
  onTaskDescriptionChange: (value: string) => void;
  onSubmit: () => void;
  repoUrl?: string;
  branch?: string;
  environmentId?: Id<"environments">;
  persistenceKey?: string;
  maxHeight?: string;
}

export const DashboardInput = memo(
  forwardRef<EditorApi, DashboardInputProps>(function DashboardInput(
    {
      onTaskDescriptionChange,
      onSubmit,
      repoUrl,
      branch,
      environmentId,
      persistenceKey,
      maxHeight = "600px",
    },
    ref
  ) {
    const internalApiRef = useRef<EditorApi | null>(null);
    const lastPointerEventRef = useRef<{
      ts: number;
      target: EventTarget | null;
    }>({
      ts: 0,
      target: null,
    });
    const lastKeydownRef = useRef<{
      ts: number;
      key: string;
      code: string;
      metaKey: boolean;
      ctrlKey: boolean;
      altKey: boolean;
    }>({
      ts: 0,
      key: "",
      code: "",
      metaKey: false,
      ctrlKey: false,
      altKey: false,
    });
    const pendingRefocusTimeoutRef = useRef<number | null>(null);

    useImperativeHandle(ref, () => ({
      getContent: () =>
        internalApiRef.current?.getContent() || { text: "", images: [] },
      clear: () => internalApiRef.current?.clear(),
      focus: () => internalApiRef.current?.focus?.(),
      insertText: (text: string) => internalApiRef.current?.insertText?.(text),
    }));

    useEffect(() => {
      const lexicalRootSelector = ".dashboard-input-editor";
      // const isDev = import.meta.env.DEV;
      const isDev = false;

      const clearPendingRefocus = () => {
        if (pendingRefocusTimeoutRef.current !== null) {
          window.clearTimeout(pendingRefocusTimeoutRef.current);
          pendingRefocusTimeoutRef.current = null;
        }
      };

      const describeElement = (target: EventTarget | null) => {
        if (!(target instanceof Element)) {
          return target ? String(target) : "<null>";
        }

        const id = target.id ? `#${target.id}` : "";
        const className = target.className
          ? `.${target.className.toString().trim().replace(/\s+/g, ".")}`
          : "";
        const title =
          target instanceof HTMLIFrameElement && target.title
            ? `(${target.title})`
            : "";

        return `${target.tagName.toLowerCase()}${id}${className}${title}`;
      };

      const scheduleRefocus = () => {
        clearPendingRefocus();
        pendingRefocusTimeoutRef.current = window.setTimeout(() => {
          pendingRefocusTimeoutRef.current = null;
          internalApiRef.current?.focus?.();
        }, 0);
      };

      const shouldRestoreFocus = (
        event: FocusEvent,
        candidateActiveElement: Element | null
      ) => {
        if (!document.hasFocus()) {
          return false;
        }

        const targetElement =
          event.target instanceof Element ? event.target : null;
        if (!targetElement?.closest(lexicalRootSelector)) {
          return false;
        }

        if (
          candidateActiveElement &&
          targetElement.contains(candidateActiveElement)
        ) {
          return false;
        }

        const now = Date.now();
        const recentPointer = lastPointerEventRef.current;
        if (
          recentPointer.ts !== 0 &&
          now - recentPointer.ts < 400 &&
          recentPointer.target instanceof Element &&
          !recentPointer.target.closest(lexicalRootSelector)
        ) {
          return false;
        }

        const recentKeydown = lastKeydownRef.current;
        if (
          recentKeydown.ts !== 0 &&
          now - recentKeydown.ts < 400 &&
          (recentKeydown.key === "Tab" || recentKeydown.code === "Tab")
        ) {
          return false;
        }

        if (!candidateActiveElement) {
          return true;
        }

        if (
          candidateActiveElement instanceof HTMLIFrameElement &&
          candidateActiveElement.title.toLowerCase().includes("vscode")
        ) {
          return true;
        }

        return candidateActiveElement.tagName === "BODY";
      };

      const handleFocusEvent = (event: FocusEvent) => {
        const activeElement = document.activeElement;
        const shouldRefocusImmediately =
          event.type === "focusout" &&
          shouldRestoreFocus(
            event,
            activeElement instanceof Element ? activeElement : null
          );

        if (isDev) {
          const payload = {
            eventTarget: describeElement(event.target),
            relatedTarget: describeElement(event.relatedTarget),
            activeElement: describeElement(activeElement),
            timestamp: new Date().toISOString(),
            hasDocumentFocus: document.hasFocus(),
          };
          console.log("[DashboardInput] focus event", event.type, payload);
          if (event.type === "focusout") {
            console.trace("[DashboardInput] focusout stack trace");
          }
        }

        if (shouldRefocusImmediately) {
          scheduleRefocus();
        }

        queueMicrotask(() => {
          const elementAfterMicrotask = document.activeElement;
          const shouldRefocusAfterMicrotask =
            event.type === "focusout" &&
            shouldRestoreFocus(
              event,
              elementAfterMicrotask instanceof Element
                ? elementAfterMicrotask
                : null
            );

          if (isDev) {
            console.log(
              "[DashboardInput] activeElement after microtask",
              event.type,
              {
                activeElement: describeElement(elementAfterMicrotask),
                timestamp: new Date().toISOString(),
                hasDocumentFocus: document.hasFocus(),
              }
            );
          }

          if (shouldRefocusAfterMicrotask) {
            scheduleRefocus();
          }
        });
      };

      const handlePointerEvent = (event: PointerEvent) => {
        lastPointerEventRef.current = {
          ts: Date.now(),
          target: event.target,
        };

        if (isDev) {
          console.log("[DashboardInput] pointer event", event.type, {
            eventTarget: describeElement(event.target),
            pointerType: event.pointerType,
            buttons: event.buttons,
            clientX: event.clientX,
            clientY: event.clientY,
            activeElement: describeElement(document.activeElement),
            timestamp: new Date().toISOString(),
          });
        }
      };

      const handleKeyEvent = (event: KeyboardEvent) => {
        if (event.type === "keydown") {
          lastKeydownRef.current = {
            ts: Date.now(),
            key: event.key,
            code: event.code,
            metaKey: event.metaKey,
            ctrlKey: event.ctrlKey,
            altKey: event.altKey,
          };
        }

        if (isDev) {
          console.log("[DashboardInput] keyboard event", event.type, {
            key: event.key,
            code: event.code,
            metaKey: event.metaKey,
            ctrlKey: event.ctrlKey,
            altKey: event.altKey,
            eventTarget: describeElement(event.target),
            activeElement: describeElement(document.activeElement),
            timestamp: new Date().toISOString(),
          });
        }
      };

      document.addEventListener("focusin", handleFocusEvent, true);
      document.addEventListener("focusout", handleFocusEvent, true);
      document.addEventListener("pointerdown", handlePointerEvent, true);
      document.addEventListener("pointerup", handlePointerEvent, true);
      document.addEventListener("keydown", handleKeyEvent, true);
      document.addEventListener("keyup", handleKeyEvent, true);

      return () => {
        clearPendingRefocus();
        document.removeEventListener("focusin", handleFocusEvent, true);
        document.removeEventListener("focusout", handleFocusEvent, true);
        document.removeEventListener("pointerdown", handlePointerEvent, true);
        document.removeEventListener("pointerup", handlePointerEvent, true);
        document.removeEventListener("keydown", handleKeyEvent, true);
        document.removeEventListener("keyup", handleKeyEvent, true);
      };
    }, []);

    useEffect(() => {
      if (!isElectron) {
        return;
      }

      const handleContextMenu = (event: MouseEvent) => {
        const target = event.target;
        const elementTarget =
          target instanceof Element
            ? target
            : target instanceof Text
              ? target.parentElement
              : null;

        if (!elementTarget) {
          return;
        }

        if (!elementTarget.closest(".dashboard-input-editor")) {
          return;
        }

        const bridge = window as typeof window & {
          cmux?: {
            ui?: {
              showEditContextMenu?: (position?: {
                x?: number;
                y?: number;
              }) => Promise<{ ok: boolean }>;
            };
          };
        };
        const showMenu = bridge.cmux?.ui?.showEditContextMenu;
        if (!showMenu) {
          return;
        }

        event.preventDefault();
        const x = Number.isFinite(event.screenX) ? event.screenX : undefined;
        const y = Number.isFinite(event.screenY) ? event.screenY : undefined;

        void showMenu({ x, y });
      };

      document.addEventListener("contextmenu", handleContextMenu);

      return () => {
        document.removeEventListener("contextmenu", handleContextMenu);
      };
    }, []);

    const lexicalPlaceholder = useMemo(() => "Describe a task", []);

    const lexicalPadding = useMemo(
      () => ({
        paddingLeft: "14px",
        paddingRight: "16px",
        paddingTop: "14px",
      }),
      []
    );

    const lexicalClassName = useMemo(
      () =>
        clsx(
          "text-[15px] text-neutral-900 dark:text-neutral-100 min-h-[60px]! dashboard-input-editor",
          "focus:outline-none"
        ),
      []
    );

    const handleEditorReady = (api: EditorApi) => {
      internalApiRef.current = api;
    };

    return (
      <LexicalEditor
        placeholder={lexicalPlaceholder}
        onChange={onTaskDescriptionChange}
        onSubmit={onSubmit}
        repoUrl={repoUrl}
        branch={branch}
        environmentId={environmentId}
        persistenceKey={persistenceKey}
        padding={lexicalPadding}
        contentEditableClassName={lexicalClassName}
        maxHeight={maxHeight}
        onEditorReady={handleEditorReady}
      />
    );
  })
);
