import Prism from "prismjs";
if (typeof globalThis.Prism === "undefined") {
  globalThis.Prism = Prism;
}

import { editorStorage } from "@/lib/editorStorage";
import { CodeNode } from "@lexical/code";
import { AutoLinkNode, LinkNode } from "@lexical/link";
import { ListItemNode, ListNode } from "@lexical/list";
import { TRANSFORMERS } from "@lexical/markdown";
import { AutoFocusPlugin } from "@lexical/react/LexicalAutoFocusPlugin";
import { LexicalComposer } from "@lexical/react/LexicalComposer";
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext";
import { ContentEditable } from "@lexical/react/LexicalContentEditable";
import { LexicalErrorBoundary } from "@lexical/react/LexicalErrorBoundary";
import { HistoryPlugin } from "@lexical/react/LexicalHistoryPlugin";
import { LinkPlugin } from "@lexical/react/LexicalLinkPlugin";
import { ListPlugin } from "@lexical/react/LexicalListPlugin";
import { MarkdownShortcutPlugin } from "@lexical/react/LexicalMarkdownShortcutPlugin";
import { OnChangePlugin } from "@lexical/react/LexicalOnChangePlugin";
import { RichTextPlugin } from "@lexical/react/LexicalRichTextPlugin";
import { HeadingNode, QuoteNode } from "@lexical/rich-text";
import clsx from "clsx";
import type { Id } from "@cmux/convex/dataModel";
import {
  $createParagraphNode,
  $getRoot,
  COMMAND_PRIORITY_HIGH,
  INSERT_LINE_BREAK_COMMAND,
  KEY_DOWN_COMMAND,
  KEY_ENTER_COMMAND,
  type SerializedEditorState,
} from "lexical";
import { useCallback, useEffect, useMemo, useRef } from "react";
import { EditorStatePlugin } from "./EditorStatePlugin";
import { ImageNode } from "./ImageNode";
import { ImagePlugin } from "./ImagePlugin";
import { MentionPlugin } from "./MentionPlugin";

// Minimal shape of a serialized Lexical node we care about
interface SerializedNodeLike {
  type?: string;
  src?: string;
  imageId?: string;
  children?: Array<SerializedNodeLike>;
  // Preserve unknown properties when transforming
  [key: string]: unknown;
}

const theme = {
  ltr: "ltr",
  rtl: "rtl",
  paragraph: "editor-paragraph",
  quote: "editor-quote",
  heading: {
    h1: "editor-heading-h1",
    h2: "editor-heading-h2",
    h3: "editor-heading-h3",
    h4: "editor-heading-h4",
    h5: "editor-heading-h5",
  },
  list: {
    nested: {
      listitem: "editor-nested-listitem",
    },
    ol: "editor-list-ol",
    ul: "editor-list-ul",
    listitem: "editor-listitem",
  },
  image: "editor-image",
  link: "editor-link",
  text: {
    bold: "editor-text-bold",
    italic: "editor-text-italic",
    overflowed: "editor-text-overflowed",
    hashtag: "editor-text-hashtag",
    underline: "editor-text-underline",
    strikethrough: "editor-text-strikethrough",
    underlineStrikethrough: "editor-text-underlineStrikethrough",
    code: "editor-text-code",
  },
  code: "editor-code",
  codeHighlight: {
    atrule: "editor-tokenAttr",
    attr: "editor-tokenAttr",
    boolean: "editor-tokenProperty",
    builtin: "editor-tokenSelector",
    cdata: "editor-tokenComment",
    char: "editor-tokenSelector",
    class: "editor-tokenFunction",
    className: "editor-tokenFunction",
    comment: "editor-tokenComment",
    constant: "editor-tokenProperty",
    deleted: "editor-tokenProperty",
    doctype: "editor-tokenComment",
    entity: "editor-tokenOperator",
    function: "editor-tokenFunction",
    important: "editor-tokenVariable",
    inserted: "editor-tokenSelector",
    keyword: "editor-tokenAttr",
    namespace: "editor-tokenVariable",
    number: "editor-tokenProperty",
    operator: "editor-tokenOperator",
    prolog: "editor-tokenComment",
    property: "editor-tokenProperty",
    punctuation: "editor-tokenPunctuation",
    regex: "editor-tokenVariable",
    selector: "editor-tokenSelector",
    string: "editor-tokenSelector",
    symbol: "editor-tokenProperty",
    tag: "editor-tokenProperty",
    url: "editor-tokenOperator",
    variable: "editor-tokenVariable",
  },
};

function onError(error: Error) {
  console.error(error);
}

// Custom plugin to handle keyboard commands
function KeyboardCommandPlugin({ onSubmit }: { onSubmit?: () => void }) {
  const [editor] = useLexicalComposerContext();

  useEffect(() => {
    // Handle Cmd/Ctrl+Enter for submit
    const unregisterEnter = editor.registerCommand(
      KEY_ENTER_COMMAND,
      (event: KeyboardEvent) => {
        if ((event.metaKey || event.ctrlKey) && onSubmit) {
          event.preventDefault();
          onSubmit();
          return true;
        }
        return false;
      },
      COMMAND_PRIORITY_HIGH
    );

    // Map Ctrl+J to a soft line break (newline)
    const unregisterCtrlJ = editor.registerCommand(
      KEY_DOWN_COMMAND,
      (event: KeyboardEvent) => {
        // Newline on Ctrl+J without other modifiers
        if (
          event.ctrlKey &&
          !event.shiftKey &&
          !event.altKey &&
          (event.key === "j" || event.key === "J")
        ) {
          event.preventDefault();
          editor.dispatchCommand(INSERT_LINE_BREAK_COMMAND, false);
          return true;
        }
        return false;
      },
      COMMAND_PRIORITY_HIGH
    );

    return () => {
      unregisterEnter();
      unregisterCtrlJ();
    };
  }, [editor, onSubmit]);

  return null;
}

// Plugin to clear editor when value prop is empty
function ClearEditorPlugin({ value }: { value?: string }) {
  const [editor] = useLexicalComposerContext();
  const previousValue = useRef(value);

  useEffect(() => {
    if (value === "" && previousValue.current !== "") {
      editor.update(() => {
        const root = $getRoot();
        root.clear();
        const paragraph = $createParagraphNode();
        root.append(paragraph);
        paragraph.select();
      });
    }
    previousValue.current = value;
  }, [editor, value]);

  return null;
}

// Plugin to persist editor state to localStorage + IndexedDB
function LocalStoragePersistencePlugin({
  persistenceKey,
  clearOnSubmit,
}: {
  persistenceKey?: string;
  clearOnSubmit?: boolean;
}) {
  const [editor] = useLexicalComposerContext();
  const isFirstRender = useRef(true);
  const debounceTimer = useRef<ReturnType<typeof setTimeout> | undefined>(
    undefined
  );

  // Generate a unique ID for each image
  const generateImageId = (src: string): string => {
    // Use a hash of the first part of the image data as ID
    const hash = src
      .slice(0, 100)
      .split("")
      .reduce((a, b) => {
        const h = (a << 5) - a + b.charCodeAt(0);
        return h & h;
      }, 0);
    return `img_${Math.abs(hash)}_${Date.now()}`;
  };

  // Extract images and replace with IDs
  const extractImages = useCallback(
    async (
      state: SerializedEditorState
    ): Promise<{
      cleanState: SerializedEditorState;
      imageMap: Array<{ id: string; src: string }>;
      activeImageIds: Set<string>;
    }> => {
      const imageMap: Array<{ id: string; src: string }> = [];
      const activeImageIds = new Set<string>();

      const processNode = (node: SerializedNodeLike): SerializedNodeLike => {
        if (node.type === "image" && node.src) {
          // If it's a base64 image, store it in IndexedDB
          if (typeof node.src === "string" && node.src.startsWith("data:")) {
            const imageId =
              (typeof node.imageId === "string" && node.imageId) ||
              generateImageId(node.src);
            imageMap.push({ id: imageId, src: node.src });
            activeImageIds.add(imageId);

            return {
              ...node,
              src: undefined, // Remove the large src
              imageId, // Store just the ID
            };
          }
        }

        if (Array.isArray(node.children)) {
          return {
            ...node,
            children: node.children.map(processNode),
          };
        }

        return node;
      };

      const cleanRoot = processNode(
        state.root as unknown as SerializedNodeLike
      ) as unknown as SerializedEditorState["root"];
      const cleanState: SerializedEditorState = {
        ...state,
        root: cleanRoot,
      };

      return { cleanState, imageMap, activeImageIds };
    },
    []
  );

  // Restore images from IDs
  const restoreImages = useCallback(
    async (state: SerializedEditorState): Promise<SerializedEditorState> => {
      const imageIds: string[] = [];

      // Collect all image IDs
      const collectImageIds = (node: SerializedNodeLike): void => {
        if (
          node.type === "image" &&
          typeof node.imageId === "string" &&
          !node.src
        ) {
          imageIds.push(node.imageId);
        }
        if (Array.isArray(node.children)) {
          node.children.forEach(collectImageIds);
        }
      };

      collectImageIds(state.root as unknown as SerializedNodeLike);

      // Fetch all images from IndexedDB
      const imageMap = await editorStorage.getImages(imageIds);

      // Restore images in the state
      const processNode = (node: SerializedNodeLike): SerializedNodeLike => {
        if (
          node.type === "image" &&
          typeof node.imageId === "string" &&
          !node.src
        ) {
          const src = imageMap.get(node.imageId);
          if (src) {
            return {
              ...node,
              src,
            };
          }
        }

        if (Array.isArray(node.children)) {
          return {
            ...node,
            children: node.children.map(processNode),
          };
        }

        return node;
      };

      const restoredRoot = processNode(
        state.root as unknown as SerializedNodeLike
      ) as unknown as SerializedEditorState["root"];
      return {
        ...state,
        root: restoredRoot,
      };
    },
    []
  );

  // Load initial state from localStorage + IndexedDB
  useEffect(() => {
    if (!persistenceKey || !isFirstRender.current) return;

    isFirstRender.current = false;

    const loadState = async () => {
      const savedState = localStorage.getItem(persistenceKey);

      if (savedState) {
        try {
          const parsedState = JSON.parse(savedState) as SerializedEditorState;
          // Restore images from IndexedDB
          const restoredState = await restoreImages(parsedState);
          const editorState = editor.parseEditorState(restoredState);
          editor.setEditorState(editorState);
        } catch (error) {
          console.error("Failed to restore editor state:", error);
          // Clear corrupted state
          localStorage.removeItem(persistenceKey);
        }
      }
    };

    loadState();
  }, [editor, persistenceKey, restoreImages]);

  // Save state to localStorage + IndexedDB on changes
  useEffect(() => {
    if (!persistenceKey) return;

    // Store the latest editor state in a ref for immediate access
    const latestStateRef = { current: null as SerializedEditorState | null };

    const unregister = editor.registerUpdateListener(({ editorState }) => {
      // Update the latest state ref immediately
      latestStateRef.current = editorState.toJSON();

      // Clear existing timer
      if (debounceTimer.current) {
        clearTimeout(debounceTimer.current);
      }

      // Set new timer for debounced save
      debounceTimer.current = setTimeout(async () => {
        if (latestStateRef.current) {
          try {
            // Extract images and get clean state
            const { cleanState, imageMap, activeImageIds } =
              await extractImages(latestStateRef.current);

            // Save images to IndexedDB
            if (imageMap.length > 0) {
              await editorStorage.saveImages(imageMap);
            }

            // Clean up orphaned images that are no longer in the editor
            await editorStorage.cleanupOrphanedImages(activeImageIds);

            // Save clean state to localStorage
            const serialized = JSON.stringify(cleanState);
            localStorage.setItem(persistenceKey, serialized);
          } catch (error) {
            console.error("Failed to save editor state:", error);
            if (
              error instanceof DOMException &&
              error.name === "QuotaExceededError"
            ) {
              localStorage.removeItem(persistenceKey);
            }
          }
        }
      }, 500); // 500ms debounce
    });

    // Save immediately before page unload
    const handleBeforeUnload = async () => {
      // Cancel any pending debounced save
      if (debounceTimer.current) {
        clearTimeout(debounceTimer.current);
      }

      // Save the latest state immediately
      if (latestStateRef.current) {
        try {
          const { cleanState, imageMap, activeImageIds } = await extractImages(
            latestStateRef.current
          );

          // Save images to IndexedDB
          if (imageMap.length > 0) {
            await editorStorage.saveImages(imageMap);
          }

          // Clean up orphaned images
          await editorStorage.cleanupOrphanedImages(activeImageIds);

          // Save clean state to localStorage
          localStorage.setItem(persistenceKey, JSON.stringify(cleanState));
        } catch (error) {
          console.error("Failed to save editor state on unload:", error);
        }
      }
    };

    window.addEventListener("beforeunload", handleBeforeUnload);

    return () => {
      unregister();
      window.removeEventListener("beforeunload", handleBeforeUnload);
      if (debounceTimer.current) {
        clearTimeout(debounceTimer.current);
      }
    };
  }, [editor, persistenceKey, extractImages]);

  // Clear localStorage and IndexedDB when content is cleared (e.g., after submit)
  useEffect(() => {
    if (!persistenceKey || !clearOnSubmit) return;

    const unregister = editor.registerUpdateListener(({ editorState }) => {
      editorState.read(() => {
        const root = $getRoot();
        const children = root.getChildren();
        const isEmpty =
          children.length === 0 ||
          (children.length === 1 && children[0].getTextContent().trim() === "");

        if (isEmpty) {
          localStorage.removeItem(persistenceKey);
          // Also clear all images from IndexedDB when editor is cleared
          editorStorage.clear().catch(console.error);
        }
      });
    });

    return unregister;
  }, [editor, persistenceKey, clearOnSubmit]);

  return null;
}

type EditorImage =
  | {
      src: string;
      fileName?: string;
      altText: string;
    }
  | {
      storageId: Id<"_storage">;
      fileName?: string;
      altText: string;
    };

interface LexicalEditorProps {
  placeholder?: string;
  onChange?: (text: string) => void;
  className?: string;
  contentEditableClassName?: string;
  padding?: React.CSSProperties;
  onSubmit?: () => void;
  value?: string;
  repoUrl?: string;
  branch?: string;
  environmentId?: Id<"environments">;
  persistenceKey?: string; // Key for localStorage persistence
  maxHeight?: string;
  minHeight?: string;
  onEditorReady?: (editor: {
    getContent: () => {
      text: string;
      images: EditorImage[];
    };
    clear: () => void;
  }) => void;
}

export default function LexicalEditor({
  placeholder = "Start typing...",
  onChange,
  className,
  contentEditableClassName,
  padding,
  onSubmit,
  value,
  repoUrl,
  branch,
  environmentId,
  persistenceKey,
  maxHeight,
  minHeight,
  onEditorReady,
}: LexicalEditorProps) {
  const initialConfig = useMemo(
    () => ({
      namespace: "TaskEditor",
      theme,
      onError,
      nodes: [
        HeadingNode,
        ListNode,
        ListItemNode,
        QuoteNode,
        CodeNode,
        LinkNode,
        AutoLinkNode,
        ImageNode,
      ],
    }),
    []
  );

  return (
    <LexicalComposer initialConfig={initialConfig}>
      <div className={clsx("editor-container", className)}>
        <RichTextPlugin
          contentEditable={
            <ContentEditable
              className={clsx(
                "editor-input",
                "outline-none",
                contentEditableClassName
              )}
              style={{
                ...padding,
                maxHeight: maxHeight,
                minHeight: minHeight ?? "60px",
                overflowY: maxHeight ? "auto" : undefined,
              }}
              aria-placeholder={placeholder}
              placeholder={
                <div
                  className="editor-placeholder pointer-events-none select-none text-neutral-900"
                  style={padding}
                >
                  {placeholder}
                </div>
              }
              data-cmux-input="true"
            />
          }
          ErrorBoundary={LexicalErrorBoundary}
        />
        <OnChangePlugin
          onChange={(editorState) => {
            editorState.read(() => {
              const root = $getRoot();
              const text = root.getTextContent();
              onChange?.(text);
            });
          }}
        />
        <HistoryPlugin />
        <AutoFocusPlugin />
        <ListPlugin />
        <LinkPlugin />
        <MarkdownShortcutPlugin transformers={TRANSFORMERS} />
        <KeyboardCommandPlugin onSubmit={onSubmit} />
        <ClearEditorPlugin value={value} />
        <LocalStoragePersistencePlugin
          persistenceKey={persistenceKey}
          clearOnSubmit={true}
        />
        <MentionPlugin
          repoUrl={repoUrl}
          branch={branch}
          environmentId={environmentId}
        />
        <ImagePlugin />
        <EditorStatePlugin onEditorReady={onEditorReady} />
      </div>
    </LexicalComposer>
  );
}
