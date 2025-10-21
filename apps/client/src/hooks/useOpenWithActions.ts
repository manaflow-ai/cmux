import { useSocket } from "@/contexts/socket/use-socket";
import type { Doc, Id } from "@cmux/convex/dataModel";
import { editorIcons, type EditorType } from "@/components/ui/dropdown-types";
import { useCallback, useEffect, useMemo } from "react";
import { toast } from "sonner";

type NetworkingInfo = Doc<"taskRuns">["networking"];

type OpenWithAction = {
  id: EditorType;
  name: string;
  Icon: (typeof editorIcons)[EditorType] | null;
};

type PortAction = {
  port: number;
  url: string;
};

type UseOpenWithActionsArgs = {
  vscodeUrl?: string | null;
  worktreePath?: string | null;
  branch?: string | null;
  networking?: NetworkingInfo;
  environmentId?: Id<"environments"> | null;
  repoUrl?: string | null;
};

export function useOpenWithActions({
  vscodeUrl,
  worktreePath,
  branch,
  networking,
  environmentId,
  repoUrl,
}: UseOpenWithActionsArgs) {
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
        } else {
          const hasWorkspace = Boolean(worktreePath) || Boolean(environmentId);
          if (
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
            hasWorkspace
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
                path: worktreePath ?? "",
                ...(environmentId ? { environmentId } : {}),
                ...(repoUrl ? { repoUrl } : {}),
                ...(branch ? { branch } : {}),
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
        }
      });
    },
    [socket, worktreePath, vscodeUrl, environmentId, repoUrl, branch]
  );

  const handleCopyBranch = useCallback(() => {
    if (!branch) return;
    navigator.clipboard
      .writeText(branch)
      .then(() => {
        toast.success(`Copied branch: ${branch}`);
      })
      .catch(() => {
        toast.error("Failed to copy branch");
      });
  }, [branch]);

  const openWithActions = useMemo<OpenWithAction[]>(() => {
    const hasWorkspace = Boolean(worktreePath) || Boolean(environmentId);
    const baseItems: Array<{ id: EditorType; name: string; enabled: boolean }> = [
      { id: "vscode-remote", name: "VS Code (web)", enabled: Boolean(vscodeUrl) },
      {
        id: "vscode",
        name: "VS Code (local)",
        enabled: hasWorkspace && (availableEditors?.vscode ?? true),
      },
      {
        id: "cursor",
        name: "Cursor",
        enabled: hasWorkspace && (availableEditors?.cursor ?? true),
      },
      {
        id: "windsurf",
        name: "Windsurf",
        enabled: hasWorkspace && (availableEditors?.windsurf ?? true),
      },
      {
        id: "finder",
        name: "Finder",
        enabled: hasWorkspace && (availableEditors?.finder ?? true),
      },
      {
        id: "iterm",
        name: "iTerm",
        enabled: hasWorkspace && (availableEditors?.iterm ?? false),
      },
      {
        id: "terminal",
        name: "Terminal",
        enabled: hasWorkspace && (availableEditors?.terminal ?? false),
      },
      {
        id: "ghostty",
        name: "Ghostty",
        enabled: hasWorkspace && (availableEditors?.ghostty ?? false),
      },
      {
        id: "alacritty",
        name: "Alacritty",
        enabled: hasWorkspace && (availableEditors?.alacritty ?? false),
      },
      {
        id: "xcode",
        name: "Xcode",
        enabled: hasWorkspace && (availableEditors?.xcode ?? false),
      },
    ];

    return baseItems
      .filter((item) => item.enabled)
      .map((item) => ({
        id: item.id,
        name: item.name,
        Icon: editorIcons[item.id] ?? null,
      }));
  }, [availableEditors, vscodeUrl, worktreePath, environmentId]);

  const portActions = useMemo<PortAction[]>(() => {
    if (!networking) return [];
    return networking
      .filter((service) => service.status === "running")
      .map((service) => ({
        port: service.port,
        url: service.url,
      }));
  }, [networking]);

  const executeOpenAction = useCallback(
    (action: OpenWithAction) => {
      const loadingToast = toast.loading(`Opening ${action.name}...`);
      handleOpenInEditor(action.id)
        .then(() => {
          toast.success(`Opened ${action.name}`, {
            id: loadingToast,
          });
        })
        .catch((error) => {
          let errorMessage = "Failed to open editor";

          if (
            error.message?.includes("ENOENT") ||
            error.message?.includes("not found") ||
            error.message?.includes("command not found")
          ) {
            errorMessage = `${action.name} is not installed or not found in PATH`;
          } else if (error.message) {
            errorMessage = error.message;
          }

          toast.error(errorMessage, {
            id: loadingToast,
          });
        });
    },
    [handleOpenInEditor]
  );

  const executePortAction = useCallback((port: PortAction) => {
    window.open(port.url, "_blank", "noopener,noreferrer");
  }, []);

  return {
    actions: openWithActions,
    executeOpenAction,
    copyBranch: branch ? handleCopyBranch : undefined,
    ports: portActions,
    executePortAction,
  } as const;
}

export type { OpenWithAction, PortAction };
