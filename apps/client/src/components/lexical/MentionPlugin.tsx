import type { FileInfo } from "@cmux/shared";
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext";
import clsx from "clsx";
import fuzzysort from "fuzzysort";
import {
  $getSelection,
  $isRangeSelection,
  $isTextNode,
  BLUR_COMMAND,
  COMMAND_PRIORITY_HIGH,
  KEY_ARROW_DOWN_COMMAND,
  KEY_ARROW_UP_COMMAND,
  KEY_ENTER_COMMAND,
  KEY_ESCAPE_COMMAND,
  TextNode,
} from "lexical";
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { getIconForFile } from "vscode-icons-js";
import { isElectron } from "@/lib/electron";
import { useSocket } from "../../contexts/socket/use-socket";

const MENTION_TRIGGER = "@";

interface MentionMenuProps {
  files: FileInfo[];
  selectedIndex: number;
  onSelect: (file: FileInfo) => void;
  position: { top: number; left: number } | null;
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

  useEffect(() => {
    if (menuRef.current && selectedIndex >= 0) {
      const selectedElement = menuRef.current.children[
        selectedIndex
      ] as HTMLElement;
      if (selectedElement) {
        selectedElement.scrollIntoView({ block: "nearest" });
      }
    }
  }, [selectedIndex]);

  if (!position) return null;

  return createPortal(
    <div
      ref={menuRef}
      className="absolute z-[var(--z-modal)] max-h-48 overflow-y-auto bg-white dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-700 rounded-md shadow-lg max-w-[580px]"
      style={{
        top: position.top,
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
        files.map((file, index) => {
          const rel = file.relativePath.replace(/\\/g, "/");
          const lastSlash = rel.lastIndexOf("/");
          const dirPath = lastSlash > -1 ? rel.slice(0, lastSlash) : "";
          const fileName = file.name || (lastSlash > -1 ? rel.slice(lastSlash + 1) : rel);
          return (
          <button
            key={file.relativePath}
            onClick={() => onSelect(file)}
            className={clsx(
              "w-full text-left px-2.5 py-1 text-xs flex items-center gap-1.5",
              index === selectedIndex
                ? "bg-blue-100 dark:bg-blue-900/30 text-blue-900 dark:text-blue-100"
                : "hover:bg-neutral-100 dark:hover:bg-neutral-700 text-neutral-900 dark:text-neutral-100"
            )}
            type="button"
          >
            <img
              src={`https://cdn.jsdelivr.net/gh/vscode-icons/vscode-icons/icons/${file.name === "Dockerfile" ? "file_type_docker.svg" : getIconForFile(file.name)}`}
              alt=""
              className="w-3 h-3 flex-shrink-0"
            />
            <div className="flex items-center gap-1 min-w-0 whitespace-nowrap">
              <span className="truncate font-medium">{fileName}</span>
              {dirPath ? (
                <span className="truncate text-neutral-500 dark:text-neutral-400">{dirPath}</span>
              ) : null}
            </div>
          </button>
          );
        })
      )}
    </div>,
    document.body
  );
}

interface MentionPluginProps {
  repoUrl?: string;
  branch?: string;
}

export function MentionPlugin({ repoUrl, branch }: MentionPluginProps) {
  const [editor] = useLexicalComposerContext();
  const [isShowingMenu, setIsShowingMenu] = useState(false);
  const [menuPosition, setMenuPosition] = useState<{
    top: number;
    left: number;
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
    if (repoUrl && socket) {
      setIsLoading(true);
      const eventName = isElectron ? "list-files-native" : "list-files";
      socket.emit(eventName, {
        repoPath: repoUrl,
        branch: branch || undefined,
        // Don't send pattern - we want all files
      });

      const handleFilesResponse = (data: {
        files: FileInfo[];
        error?: string;
      }) => {
        setIsLoading(false);
        if (!data.error) {
          // Filter to only show actual files, not directories
          const fileList = data.files.filter((f) => !f.isDirectory);
          setFiles(fileList);
        } else {
          setFiles([]);
        }
      };

      socket.on("list-files-response", handleFilesResponse);

      return () => {
        socket.off("list-files-response", handleFilesResponse);
      };
    } else if (!repoUrl) {
      // If no repository URL, set empty files list
      setFiles([]);
      setIsLoading(false);
    }
  }, [repoUrl, branch, socket]);

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
      // Store the trigger node before it gets cleared
      const currentTriggerNode = triggerNodeRef.current;

      editor.update(() => {
        const selection = $getSelection();

        if ($isRangeSelection(selection) && currentTriggerNode) {
          const triggerText = currentTriggerNode.getTextContent();
          const mentionStartIndex = triggerText.lastIndexOf(MENTION_TRIGGER);

          if (mentionStartIndex !== -1) {
            // Replace @ and search text with @filename and a space
            currentTriggerNode.spliceText(
              mentionStartIndex,
              triggerText.length - mentionStartIndex,
              `@${file.relativePath} `,
              true
            );
          }
        }
      });
      hideMenu();
    },
    [editor, hideMenu]
  );

  useEffect(() => {
    const checkForMentionTrigger = () => {
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

        // Calculate menu position
        const domSelection = window.getSelection();
        if (domSelection && domSelection.rangeCount > 0) {
          const range = domSelection.getRangeAt(0);
          const rect = range.getBoundingClientRect();
          setMenuPosition({
            top: rect.bottom + window.scrollY + 4,
            left: rect.left + window.scrollX,
          });
          setIsShowingMenu(true);
        }
      } else {
        hideMenu();
      }
    };

    return editor.registerUpdateListener(() => {
      editor.getEditorState().read(() => {
        checkForMentionTrigger();
      });
    });
  }, [editor, hideMenu]);

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

    // Handle Ctrl+N/P and Ctrl+J/K
    const handleKeyDown = (event: KeyboardEvent) => {
      if (!isShowingMenuRef.current) return;

      if (event.ctrlKey) {
        switch (event.key) {
          case "n":
          case "j":
            event.preventDefault();
            handleArrowDown();
            break;
          case "p":
          case "k":
            event.preventDefault();
            handleArrowUp();
            break;
        }
      }
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

    document.addEventListener("keydown", handleKeyDown);

    return () => {
      removeArrowDown();
      removeArrowUp();
      removeEnter();
      removeEscape();
      removeBlur();
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [editor, selectFile, hideMenu]);

  return (
    <MentionMenu
      files={filteredFiles}
      selectedIndex={selectedIndex}
      onSelect={selectFile}
      position={menuPosition}
      hasRepository={!!repoUrl}
      isLoading={isLoading}
    />
  );
}
