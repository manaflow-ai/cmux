import { useSocket } from "@/contexts/socket/use-socket";
import { Menu } from "@base-ui-components/react/menu";
import clsx from "clsx";
import { Check, ChevronDown, Package } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";
import { Dropdown } from "./ui/dropdown";

type EditorType = "cursor" | "vscode" | "windsurf" | "finder";

interface OpenEditorSplitButtonProps {
  worktreePath?: string | null;
  classNameLeft?: string;
  classNameRight?: string;
}

export function OpenEditorSplitButton({
  worktreePath,
  classNameLeft,
  classNameRight,
}: OpenEditorSplitButtonProps) {
  const { socket } = useSocket();
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => {
    if (!socket) return;
    const handleOpenInEditorError = (data: { error: string }) => {
      console.error("Failed to open editor:", data.error);
    };
    socket.on("open-in-editor-error", handleOpenInEditorError);
    return () => {
      socket.off("open-in-editor-error", handleOpenInEditorError);
    };
  }, [socket]);

  const menuItems = useMemo(
    () => [
      { id: "vscode" as const, name: "VS Code", enabled: !!worktreePath },
      { id: "cursor" as const, name: "Cursor", enabled: !!worktreePath },
      { id: "windsurf" as const, name: "Windsurf", enabled: !!worktreePath },
      { id: "finder" as const, name: "Finder", enabled: !!worktreePath },
    ],
    [worktreePath]
  );

  const [selectedEditor, setSelectedEditor] = useState<EditorType | null>(
    () => {
      const raw =
        typeof window !== "undefined"
          ? window.localStorage.getItem("cmux:lastEditor")
          : null;
      const stored =
        raw === "vscode-remote"
          ? worktreePath
            ? "vscode"
            : null
          : (raw as EditorType | null);
      if (stored) return stored;
      if (worktreePath) return "vscode";
      return null;
    }
  );

  useEffect(() => {
    if (selectedEditor) {
      window.localStorage.setItem("cmux:lastEditor", selectedEditor);
    }
  }, [selectedEditor]);

  const handleOpenInEditor = useCallback(
    (editor: EditorType): Promise<void> => {
      return new Promise((resolve, reject) => {
        if (
          socket &&
          ["cursor", "vscode", "windsurf", "finder"].includes(editor) &&
          worktreePath
        ) {
          socket.emit(
            "open-in-editor",
            { editor, path: worktreePath },
            (response: { success: boolean; error?: string }) => {
              if (response.success) resolve();
              else reject(new Error(response.error || "Failed to open editor"));
            }
          );
        } else {
          reject(new Error("Unable to open editor"));
        }
      });
    },
    [socket, worktreePath]
  );

  const selected = menuItems.find((m) => m.id === selectedEditor) || null;
  const leftDisabled = !selected || !selected.enabled;

  const openSelected = useCallback(() => {
    if (!selected) return;
    const name = selected.name;
    const loadingToast = toast.loading(`Opening ${name}...`);
    handleOpenInEditor(selected.id)
      .then(() => {
        toast.success(`Opened ${name}`, { id: loadingToast });
      })
      .catch((error: Error) => {
        let errorMessage = "Failed to open editor";
        if (
          error.message?.includes("ENOENT") ||
          error.message?.includes("not found") ||
          error.message?.includes("command not found")
        ) {
          if (selected.id === "vscode")
            errorMessage = "VS Code is not installed or not found in PATH";
          else if (selected.id === "cursor")
            errorMessage = "Cursor is not installed or not found in PATH";
          else if (selected.id === "windsurf")
            errorMessage = "Windsurf is not installed or not found in PATH";
          else if (selected.id === "finder")
            errorMessage = "Finder is not available or not found";
        } else if (error.message) {
          errorMessage = error.message;
        }
        toast.error(errorMessage, { id: loadingToast });
      });
  }, [handleOpenInEditor, selected]);

  return (
    <div className="flex items-stretch">
      <button
        onClick={openSelected}
        disabled={leftDisabled}
        className={clsx(
          "flex items-center gap-1.5 px-3 py-1 bg-neutral-800 text-white rounded-l hover:bg-neutral-700 disabled:opacity-50 disabled:cursor-not-allowed font-medium text-xs select-none whitespace-nowrap",
          "border border-neutral-700 border-r",
          classNameLeft
        )}
      >
        <Package className="w-3.5 h-3.5" />
        {selected ? selected.name : "Open in editor"}
      </button>
      <Menu.Root open={menuOpen} onOpenChange={setMenuOpen}>
        <Menu.Trigger
          className={clsx(
            "flex items-center px-2 py-1 bg-neutral-800 text-white rounded-r hover:bg-neutral-700 select-none border border-neutral-700 border-l-0",
            classNameRight
          )}
          title="Choose editor"
        >
          <ChevronDown className="w-3.5 h-3.5" />
        </Menu.Trigger>
        <Menu.Portal>
          <Menu.Positioner sideOffset={5} className="outline-none z-[9999]">
            <Menu.Popup
              className={clsx(
                "origin-[var(--transform-origin)] rounded-md bg-white dark:bg-black py-1",
                "text-neutral-900 dark:text-neutral-100",
                "shadow-lg shadow-neutral-200 dark:shadow-neutral-950",
                "outline outline-neutral-200 dark:outline-neutral-800",
                "transition-[transform,scale,opacity]",
                "data-[ending-style]:scale-90 data-[ending-style]:opacity-0",
                "data-[starting-style]:scale-90 data-[starting-style]:opacity-0"
              )}
            >
              <Dropdown.Arrow />
              <Menu.RadioGroup
                value={selected?.id}
                onValueChange={(val) => {
                  setSelectedEditor(val as EditorType);
                  setMenuOpen(false);
                }}
              >
                {menuItems.map((item) => (
                  <Menu.RadioItem
                    key={item.id}
                    value={item.id}
                    disabled={!item.enabled}
                    className={clsx(
                      "grid cursor-default grid-cols-[0.75rem_1fr] items-center gap-2 py-2 pr-8 pl-2.5 text-sm leading-4 outline-none select-none",
                      "data-[highlighted]:relative data-[highlighted]:z-0",
                      "data-[highlighted]:text-neutral-50 dark:data-[highlighted]:text-neutral-900",
                      "data-[highlighted]:before:absolute data-[highlighted]:before:inset-x-1 data-[highlighted]:before:inset-y-0",
                      "data-[highlighted]:before:z-[-1] data-[highlighted]:before:rounded-sm",
                      "data-[highlighted]:before:bg-neutral-900 dark:data-[highlighted]:before:bg-neutral-100",
                      "data-[disabled]:text-neutral-400 dark:data-[disabled]:text-neutral-600 data-[disabled]:cursor-not-allowed"
                    )}
                    onClick={() => setMenuOpen(false)}
                  >
                    <Menu.RadioItemIndicator className="col-start-1">
                      <Check className="w-3 h-3" />
                    </Menu.RadioItemIndicator>
                    <span className="col-start-2">{item.name}</span>
                  </Menu.RadioItem>
                ))}
              </Menu.RadioGroup>
            </Menu.Popup>
          </Menu.Positioner>
        </Menu.Portal>
      </Menu.Root>
    </div>
  );
}
