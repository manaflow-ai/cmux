import { Dropdown } from "@/components/ui/dropdown";
import { editorIcons, type EditorType } from "@/components/ui/dropdown-types";
import { useSocket } from "@/contexts/socket/use-socket";
import { isElectron } from "@/lib/electron";
import type { Doc } from "@cmux/convex/dataModel";
import clsx from "clsx";
import { EllipsisVertical, ExternalLink, GitBranch, Globe } from "lucide-react";
import { useCallback, useEffect } from "react";
import { toast } from "sonner";

interface OpenWithDropdownProps {
  vscodeUrl?: string | null;
  worktreePath?: string | null;
  branch?: string | null;
  networking?: Doc<"taskRuns">["networking"];
  className?: string;
  iconClassName?: string;
}

type MenuItem = {
  id: EditorType;
  name: string;
  enabled: boolean;
};

export function OpenWithDropdown({
  vscodeUrl,
  worktreePath,
  branch,
  networking,
  className,
  iconClassName = "w-3.5 h-3.5",
}: OpenWithDropdownProps) {
  const { socket, availableEditors } = useSocket();

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

  const handleOpenInEditor = useCallback(
    (editor: EditorType): Promise<void> => {
      return new Promise((resolve, reject) => {
        if (editor === "vscode-remote" && vscodeUrl) {
          const vscodeUrlWithWorkspace = `${vscodeUrl}?folder=/root/workspace`;
          window.open(vscodeUrlWithWorkspace, "_blank", "noopener,noreferrer");
          resolve();
        } else if (
          socket &&
          [
            "cursor",
            "vscode",
            "windsurf",
            "finder",
            "iterm",
            "terminal",
            "ghostty",
            "alacritty",
            "xcode",
          ].includes(editor) &&
          worktreePath
        ) {
          socket.emit(
            "open-in-editor",
            {
              editor: editor as
                | "cursor"
                | "vscode"
                | "windsurf"
                | "finder"
                | "iterm"
                | "terminal"
                | "ghostty"
                | "alacritty"
                | "xcode",
              path: worktreePath,
            },
            (response) => {
              if (response.success) {
                resolve();
              } else {
                reject(new Error(response.error || "Failed to open editor"));
              }
            }
          );
        } else {
          reject(new Error("Unable to open editor"));
        }
      });
    },
    [socket, worktreePath, vscodeUrl]
  );

  const handleCopyBranch = useCallback(() => {
    if (branch) {
      navigator.clipboard
        .writeText(branch)
        .then(() => {
          toast.success(`Copied branch: ${branch}`);
        })
        .catch(() => {
          toast.error("Failed to copy branch");
        });
    }
  }, [branch]);

  const menuItems: MenuItem[] = [
    {
      id: "vscode-remote" as const,
      name: "VS Code (web)",
      enabled: !!vscodeUrl,
    },
    {
      id: "vscode" as const,
      name: "VS Code (local)",
      enabled: !!worktreePath && (availableEditors?.vscode ?? true),
    },
    {
      id: "cursor" as const,
      name: "Cursor",
      enabled: !!worktreePath && (availableEditors?.cursor ?? true),
    },
    {
      id: "windsurf" as const,
      name: "Windsurf",
      enabled: !!worktreePath && (availableEditors?.windsurf ?? true),
    },
    {
      id: "finder" as const,
      name: "Finder",
      enabled: !!worktreePath && (availableEditors?.finder ?? true),
    },
    {
      id: "iterm" as const,
      name: "iTerm",
      enabled: !!worktreePath && (availableEditors?.iterm ?? false),
    },
    {
      id: "terminal" as const,
      name: "Terminal",
      enabled: !!worktreePath && (availableEditors?.terminal ?? false),
    },
    {
      id: "ghostty" as const,
      name: "Ghostty",
      enabled: !!worktreePath && (availableEditors?.ghostty ?? false),
    },
    {
      id: "alacritty" as const,
      name: "Alacritty",
      enabled: !!worktreePath && (availableEditors?.alacritty ?? false),
    },
    {
      id: "xcode" as const,
      name: "Xcode",
      enabled: !!worktreePath && (availableEditors?.xcode ?? false),
    },
  ].filter((item) => item.enabled);

  return (
    <Dropdown.Root>
      <Dropdown.Trigger
        onClick={(e) => e.stopPropagation()}
        className={clsx(
          "p-1 rounded flex items-center gap-1",
          "bg-neutral-100 dark:bg-neutral-700",
          "text-neutral-600 dark:text-neutral-400",
          "hover:bg-neutral-200 dark:hover:bg-neutral-600",
          className
        )}
        title="Open with"
      >
        {/* <Code2 className={iconClassName} />
        <ChevronDown className="w-2.5 h-2.5" /> */}
        <EllipsisVertical className={iconClassName} />
      </Dropdown.Trigger>
      <Dropdown.Portal>
        <Dropdown.Positioner
          sideOffset={8}
          side={isElectron ? "left" : "bottom"}
        >
          <Dropdown.Popup>
            <Dropdown.Arrow />
            <div className="px-2 py-1 text-xs font-medium text-neutral-500 dark:text-neutral-400 select-none">
              Open with
            </div>
            {menuItems.map((item) => {
              const Icon = editorIcons[item.id];
              return (
                <Dropdown.Item
                  key={item.id}
                  onClick={() => {
                    const loadingToast = toast.loading(
                      `Opening ${item.name}...`
                    );

                    handleOpenInEditor(item.id)
                      .then(() => {
                        toast.success(`Opened ${item.name}`, {
                          id: loadingToast,
                        });
                      })
                      .catch((error) => {
                        let errorMessage = "Failed to open editor";

                        // Handle specific error cases
                        if (
                          error.message?.includes("ENOENT") ||
                          error.message?.includes("not found") ||
                          error.message?.includes("command not found")
                        ) {
                          errorMessage = `${item.name} is not installed or not found in PATH`;
                        } else if (error.message) {
                          errorMessage = error.message;
                        }

                        toast.error(errorMessage, {
                          id: loadingToast,
                        });
                      });
                  }}
                  className="flex items-center gap-2"
                >
                  {Icon && <Icon className="w-3.5 h-3.5" />}
                  {item.name}
                </Dropdown.Item>
              );
            })}
            {branch && (
              <>
                <div className="my-1 h-px bg-neutral-200 dark:bg-neutral-700" />
                <Dropdown.Item
                  onClick={handleCopyBranch}
                  className="flex items-center gap-2"
                >
                  <GitBranch className="w-3.5 h-3.5" />
                  Copy branch
                </Dropdown.Item>
              </>
            )}
            {networking && networking.length > 0 && (
              <>
                <div className="my-1 h-px bg-neutral-200 dark:bg-neutral-700" />
                <div className="px-2 py-1 text-xs font-medium text-neutral-500 dark:text-neutral-400 select-none">
                  Forwarded ports
                </div>
                {networking
                  .filter((service) => service.status === "running")
                  .map((service) => (
                    <Dropdown.Item
                      key={service.port}
                      onClick={() => {
                        window.open(
                          service.url,
                          "_blank",
                          "noopener,noreferrer"
                        );
                      }}
                      className="flex items-center justify-between w-full pr-4!"
                    >
                      <div className="flex items-center gap-2 grow">
                        <Globe className="w-3 h-3" />
                        Port {service.port}
                      </div>
                      <ExternalLink className="w-3 h-3 text-neutral-400" />
                    </Dropdown.Item>
                  ))}
              </>
            )}
          </Dropdown.Popup>
        </Dropdown.Positioner>
      </Dropdown.Portal>
    </Dropdown.Root>
  );
}
