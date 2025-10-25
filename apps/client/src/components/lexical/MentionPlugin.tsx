import type { Id } from "@cmux/convex/dataModel";
import type { FileInfo } from "@cmux/shared";
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext";
import { useVirtualizer } from "@tanstack/react-virtual";
import clsx from "clsx";
import fuzzysort from "fuzzysort";
import {
  $getSelection,
  $isRangeSelection,
  $isTextNode,
  BLUR_COMMAND,
  COMMAND_PRIORITY_CRITICAL,
  COMMAND_PRIORITY_HIGH,
  KEY_ARROW_DOWN_COMMAND,
  KEY_ARROW_UP_COMMAND,
  KEY_DOWN_COMMAND,
  KEY_ENTER_COMMAND,
  KEY_ESCAPE_COMMAND,
  TextNode,
} from "lexical";
import type { EditorState } from "lexical";
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  DEFAULT_FILE,
  DEFAULT_FOLDER,
  getIconForFile,
  getIconForFolder,
} from "vscode-icons-js";
import { useSocket } from "../../contexts/socket/use-socket";

const MENTION_TRIGGER = "@";
const MENTION_ITEM_HEIGHT = 24;

interface MentionMenuProps {
  files: FileInfo[];
  selectedIndex: number;
  onSelect: (file: FileInfo) => void;
  position: { top: number; left: number; showAbove?: boolean } | null;
  hasRepository: boolean;
  isLoading: boolean;
}

function MentionMenu({
  files,
  selectedIndex,
  onSelect,
  position,
  hasRepository,
  isLoading,
}: MentionMenuProps) {
  const menuRef = useRef<HTMLDivElement>(null);
  const rowVirtualizer = useVirtualizer({
    count: files.length,
    getScrollElement: () => menuRef.current,
    estimateSize: () => MENTION_ITEM_HEIGHT,
    overscan: 8,
    initialRect: { width: 320, height: 192 },
  });

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    if (isLoading || files.length === 0) {
      return;
    }
    if (selectedIndex < 0 || selectedIndex >= files.length) {
      return;
    }
    const frameId = window.requestAnimationFrame(() => {
      try {
        rowVirtualizer.scrollToIndex(selectedIndex, { align: "auto" });
      } catch {
        /* noop */
      }
    });
    return () => {
      window.cancelAnimationFrame(frameId);
    };
  }, [files.length, isLoading, rowVirtualizer, selectedIndex]);

  if (!position) return null;

  const bottomOffset =
    position.showAbove && typeof document !== "undefined"
      ? Math.max(document.documentElement.scrollHeight - position.top, 0)
      : undefined;

  return createPortal(
    <div
      ref={menuRef}
      className="absolute z-[var(--z-modal)] max-h-48 overflow-y-auto bg-white dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-md shadow-lg max-w-[580px]"
      style={{
        ...(position.showAbove && bottomOffset !== undefined
          ? { bottom: `${bottomOffset}px` }
          : { top: position.top }),
        left: position.left,
      }}
    >
      {isLoading ? (
        <div className="px-2.5 py-2 text-xs text-neutral-500 dark:text-neutral-400 flex items-center gap-2">
          <svg
            className="animate-spin h-3 w-3"
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
          >
            <circle
              className="opacity-25"
              cx="12"
              cy="12"
              r="10"
              stroke="currentColor"
              strokeWidth="4"
            ></circle>
            <path
              className="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            ></path>
          </svg>
          Loading files...
        </div>
      ) : files.length === 0 ? (
        <div className="px-2.5 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
          {hasRepository
            ? "No files found"
            : "Please select a project to see files"}
        </div>
      ) : (
        <div
          style={{
            height: rowVirtualizer.getTotalSize(),
            position: "relative",
          }}
        >
          {rowVirtualizer.getVirtualItems().map((virtualRow) => {
            const file = files[virtualRow.index];
            if (!file) {
              return null;
            }
            const rel = file.relativePath.replace(/\\/g, "/");
            const lastSlash = rel.lastIndexOf("/");
            const dirPath = lastSlash > -1 ? rel.slice(0, lastSlash) : "";
            const rawName = file.name || (lastSlash > -1 ? rel.slice(lastSlash + 1) : rel);
            const displayName = file.isDirectory ? `${rawName}/` : rawName;
            const iconName = file.isDirectory
              ? getIconForFolder(rawName) || DEFAULT_FOLDER
              : rawName === "Dockerfile"
                ? "file_type_docker.svg"
                : getIconForFile(rawName) || DEFAULT_FILE;
            const iconSrc = `https://cdn.jsdelivr.net/gh/vscode-icons/vscode-icons/icons/${iconName}`;
            const isActive = virtualRow.index === selectedIndex;
            return (
              <button
                key={file.relativePath}
                onMouseDown={(e) => {
                  e.preventDefault(); // Prevent blur from closing the menu
                  onSelect(file);
                }}
                className={clsx(
                  "w-full text-left px-2.5 text-xs flex items-center gap-1.5 h-6",
                  isActive
                    ? "bg-blue-100 dark:bg-blue-900/30 text-blue-900 dark:text-blue-100"
                    : "hover:bg-neutral-100 dark:hover:bg-neutral-700 text-neutral-900 dark:text-neutral-100"
                )}
                style={{
                  position: "absolute",
                  top: 0,
                  left: 0,
                  right: 0,
                  height: virtualRow.size,
                  transform: `translateY(${virtualRow.start}px)`,
                }}
                type="button"
              >
                <img
                  src={iconSrc}
                  alt=""
                  className="w-3 h-3 flex-shrink-0"
                />
                <div className="flex items-center gap-1 min-w-0 whitespace-nowrap">
                  <span className="truncate font-medium">{displayName}</span>
                  {dirPath ? (
                    <span className="truncate text-neutral-500 dark:text-neutral-400">{dirPath}</span>
                  ) : null}
                </div>
              </button>
            );
          })}
        </div>
      )}
    </div>,
    document.body
  );
}

interface MentionPluginProps {
  repoUrl?: string;
  branch?: string;
  environmentId?: Id<"environments">;
}

export function MentionPlugin({
  repoUrl,
  branch,
  environmentId,
}: MentionPluginProps) {
  const [editor] = useLexicalComposerContext();
  const [isShowingMenu, setIsShowingMenu] = useState(false);
  const [menuPosition, setMenuPosition] = useState<{
    top: number;
    left: number;
    showAbove?: boolean;
  } | null>(null);
  const [searchText, setSearchText] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [files, setFiles] = useState<FileInfo[]>([]);
  const [filteredFiles, setFilteredFiles] = useState<FileInfo[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const triggerNodeRef = useRef<TextNode | null>(null);
  const { socket } = useSocket();

  // Fetch all files once when repository URL is available
  useEffect(() => {
    if ((repoUrl || environmentId) && socket) {
      setIsLoading(true);
      socket.emit("list-files", {
        ...(repoUrl ? { repoPath: repoUrl } : {}),
        ...(environmentId ? { environmentId } : {}),
        ...(branch ? { branch } : {}),
      });

      const handleFilesResponse = (data: {
        files: FileInfo[];
        error?: string;
      }) => {
        setIsLoading(false);
        if (!data.error) {
          setFiles(data.files);
        } else {
          setFiles([]);
        }
      };

      socket.on("list-files-response", handleFilesResponse);

      return () => {
        socket.off("list-files-response", handleFilesResponse);
      };
    }

    setFiles([]);
    setIsLoading(false);
  }, [repoUrl, branch, environmentId, socket]);

  // Filter files based on search text using fuzzysort
  useEffect(() => {
    if (searchText) {
      // Use fuzzysort for fuzzy matching
      const results = fuzzysort.go(searchText, files, {
        key: "relativePath",
        threshold: -10000, // Show all results
        limit: 50, // Limit for performance
      });

      setFilteredFiles(results.map((result) => result.obj));
      setSelectedIndex(0);
    } else {
      setFilteredFiles(files);
      setSelectedIndex(0);
    }
  }, [searchText, files]);

  const hideMenu = useCallback(() => {
    setIsShowingMenu(false);
    setMenuPosition(null);
    setSearchText("");
    setSelectedIndex(0);
    triggerNodeRef.current = null;
  }, []);

  const selectFile = useCallback(
    (file: FileInfo) => {
      const currentTriggerNode = triggerNodeRef.current;

      editor.update(() => {
        const selection = $getSelection();

        if (!$isRangeSelection(selection) || !currentTriggerNode) {
          return;
        }

        const anchorNode = selection.anchor.getNode();
        if (!anchorNode || anchorNode.getKey() !== currentTriggerNode.getKey()) {
          return;
        }

        const triggerText = currentTriggerNode.getTextContent();
        const anchorOffset = selection.anchor.offset;

        let mentionStartIndex = -1;
        for (let i = anchorOffset - 1; i >= 0; i -= 1) {
          const char = triggerText[i];
          if (char === MENTION_TRIGGER) {
            mentionStartIndex = i;
            break;
          }
          if (/\s/.test(char)) {
            break;
          }
        }

        if (mentionStartIndex === -1) {
          return;
        }

        const deleteCount = Math.max(anchorOffset - mentionStartIndex, 0);

        if (deleteCount > 0) {
          const relativePath = file.relativePath;
          const hasBackslash = relativePath.includes("\\");
          const directorySeparator = hasBackslash ? "\\" : "/";
          const pathWithSeparator =
            file.isDirectory &&
            !relativePath.endsWith("/") &&
            !relativePath.endsWith("\\")
              ? `${relativePath}${directorySeparator}`
              : relativePath;

          currentTriggerNode.spliceText(
            mentionStartIndex,
            deleteCount,
            `@${pathWithSeparator} `,
            true
          );
        }
      });
      hideMenu();
    },
    [editor, hideMenu]
  );

  const updateMenuFromSelection = useCallback(
    (editorState?: EditorState) => {
      (editorState ?? editor.getEditorState()).read(() => {
        const selection = $getSelection();
        if (!$isRangeSelection(selection) || !selection.isCollapsed()) {
          hideMenu();
          return;
        }

        const node = selection.anchor.getNode();
        if (!$isTextNode(node)) {
          hideMenu();
          return;
        }

        const text = node.getTextContent();
        const offset = selection.anchor.offset;

        // Find the last @ before the cursor
        let mentionStartIndex = -1;
        for (let i = offset - 1; i >= 0; i--) {
          if (text[i] === MENTION_TRIGGER) {
            mentionStartIndex = i;
            break;
          }
          // Stop if we hit whitespace
          if (/\s/.test(text[i])) {
            break;
          }
        }

        if (mentionStartIndex !== -1) {
          const searchQuery = text.slice(mentionStartIndex + 1, offset);
          setSearchText(searchQuery);
          triggerNodeRef.current = node;

          if (typeof window === "undefined") {
            return;
          }

          // Calculate menu position with edge collision detection
          const domSelection = window.getSelection();
          if (domSelection && domSelection.rangeCount > 0) {
            const range = domSelection.getRangeAt(0);
            const rect = range.getBoundingClientRect();

            // Menu dimensions (approximate max height from CSS: max-h-48 = 192px)
            const menuMaxHeight = 192;
            const menuGap = 4;

            // Calculate available space above and below cursor
            const spaceBelow = window.innerHeight - rect.bottom;
            const spaceAbove = rect.top;

            // Decide whether to show above or below based on available space
            const showAbove = spaceBelow < menuMaxHeight + menuGap && spaceAbove > spaceBelow;

            setMenuPosition({
              top: showAbove
                ? rect.top + window.scrollY - menuGap
                : rect.bottom + window.scrollY + menuGap,
              left: rect.left + window.scrollX,
              showAbove,
            });
            setIsShowingMenu(true);
          }
        } else {
          hideMenu();
        }
      });
    },
    [editor, hideMenu]
  );

  useEffect(() => {
    const unregister = editor.registerUpdateListener(({ editorState }) => {
      updateMenuFromSelection(editorState);
    });

    const handleResize = () => {
      updateMenuFromSelection();
    };

    if (typeof window !== "undefined") {
      window.addEventListener("resize", handleResize);
    }

    return () => {
      unregister();
      if (typeof window !== "undefined") {
        window.removeEventListener("resize", handleResize);
      }
    };
  }, [editor, updateMenuFromSelection]);

  // Store current state in refs to avoid stale closures
  const isShowingMenuRef = useRef(isShowingMenu);
  const filteredFilesRef = useRef(filteredFiles);
  const selectedIndexRef = useRef(selectedIndex);

  useEffect(() => {
    isShowingMenuRef.current = isShowingMenu;
  }, [isShowingMenu]);

  useEffect(() => {
    filteredFilesRef.current = filteredFiles;
  }, [filteredFiles]);

  useEffect(() => {
    selectedIndexRef.current = selectedIndex;
  }, [selectedIndex]);

  // Handle keyboard navigation
  useEffect(() => {
    const handleArrowDown = (event?: KeyboardEvent) => {
      if (!isShowingMenuRef.current) return false;
      if (event) {
        event.preventDefault();
        event.stopPropagation();
      }
      setSelectedIndex((prev) => {
        const maxIndex = filteredFilesRef.current.length - 1;
        return prev < maxIndex ? prev + 1 : 0;
      });
      return true;
    };

    const handleArrowUp = (event?: KeyboardEvent) => {
      if (!isShowingMenuRef.current) return false;
      if (event) {
        event.preventDefault();
        event.stopPropagation();
      }
      setSelectedIndex((prev) => {
        const maxIndex = filteredFilesRef.current.length - 1;
        return prev > 0 ? prev - 1 : maxIndex;
      });
      return true;
    };

    const handleEnter = (event?: KeyboardEvent) => {
      if (!isShowingMenuRef.current) return false;

      const files = filteredFilesRef.current;
      const index = selectedIndexRef.current;

      if (files.length > 0 && files[index]) {
        if (event) {
          event.preventDefault();
          event.stopPropagation();
        }
        selectFile(files[index]);
        return true;
      }
      return false;
    };

    const handleEscape = () => {
      if (!isShowingMenuRef.current) return false;
      hideMenu();
      return true;
    };

    const removeArrowDown = editor.registerCommand(
      KEY_ARROW_DOWN_COMMAND,
      (event) => handleArrowDown(event || undefined),
      COMMAND_PRIORITY_HIGH
    );

    const removeArrowUp = editor.registerCommand(
      KEY_ARROW_UP_COMMAND,
      (event) => handleArrowUp(event || undefined),
      COMMAND_PRIORITY_HIGH
    );

    const removeEnter = editor.registerCommand(
      KEY_ENTER_COMMAND,
      (event) => handleEnter(event || undefined),
      COMMAND_PRIORITY_HIGH
    );

    const removeEscape = editor.registerCommand(
      KEY_ESCAPE_COMMAND,
      handleEscape,
      COMMAND_PRIORITY_HIGH
    );

    // Handle Ctrl+N/P/J/K with critical priority to override other handlers
    const removeKeyDown = editor.registerCommand(
      KEY_DOWN_COMMAND,
      (event: KeyboardEvent) => {
        if (!isShowingMenuRef.current) return false;

        if (event.ctrlKey) {
          switch (event.key) {
            case "n":
            case "j":
              event.preventDefault();
              handleArrowDown();
              return true;
            case "p":
            case "k":
              event.preventDefault();
              handleArrowUp();
              return true;
          }
        }
        return false;
      },
      COMMAND_PRIORITY_CRITICAL
    );

    // Hide menu on blur
    const removeBlur = editor.registerCommand(
      BLUR_COMMAND,
      () => {
        if (isShowingMenuRef.current) {
          hideMenu();
        }
        return false;
      },
      COMMAND_PRIORITY_HIGH
    );

    return () => {
      removeArrowDown();
      removeArrowUp();
      removeEnter();
      removeEscape();
      removeKeyDown();
      removeBlur();
    };
  }, [editor, selectFile, hideMenu]);

  return (
    <MentionMenu
      files={filteredFiles}
      selectedIndex={selectedIndex}
      onSelect={selectFile}
      position={menuPosition}
      hasRepository={Boolean(repoUrl || environmentId)}
      isLoading={isLoading}
    />
  );
}
