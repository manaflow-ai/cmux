import { useSocket } from "@/contexts/socket/use-socket";
import type { Doc } from "@cmux/convex/dataModel";
import { editorIcons, type EditorType } from "@/components/ui/dropdown-types";
import { useCallback, useEffect, useMemo } from "react";
import { toast } from "sonner";
import { rewriteLocalWorkspaceUrlIfNeeded } from "@/lib/toProxyWorkspaceUrl";
import { useLocalVSCodeServeWebQuery } from "@/queries/local-vscode-serve-web";

const DEFAULT_CONTAINER_WORKSPACE = "/root/workspace";

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
};

export function useOpenWithActions({
  vscodeUrl,
  worktreePath,
  branch,
  networking,
}: UseOpenWithActionsArgs) {
  const { socket, availableEditors } = useSocket();
  const localServeWeb = useLocalVSCodeServeWebQuery();
  const localServeWebOrigin = localServeWeb.data?.baseUrl ?? null;

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
          const normalizedUrl = rewriteLocalWorkspaceUrlIfNeeded(
            vscodeUrl,
            localServeWebOrigin,
          );
          let targetUrl = normalizedUrl;
          try {
            const parsed = new URL(normalizedUrl);
            if (!parsed.searchParams.has("folder")) {
              parsed.searchParams.set("folder", DEFAULT_CONTAINER_WORKSPACE);
            }
            targetUrl = parsed.toString();
          } catch {
            if (!normalizedUrl.includes("?folder=")) {
              targetUrl = `${normalizedUrl}?folder=${encodeURIComponent(
                DEFAULT_CONTAINER_WORKSPACE,
              )}`;
            }
          }
          window.open(targetUrl, "_blank", "noopener,noreferrer");
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
    [socket, worktreePath, vscodeUrl, localServeWebOrigin]
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
    const baseItems: Array<{ id: EditorType; name: string; enabled: boolean }> = [
      { id: "vscode-remote", name: "VS Code (web)", enabled: Boolean(vscodeUrl) },
      {
        id: "vscode",
        name: "VS Code (local)",
        enabled: Boolean(worktreePath) && (availableEditors?.vscode ?? true),
      },
      {
        id: "cursor",
        name: "Cursor",
        enabled: Boolean(worktreePath) && (availableEditors?.cursor ?? true),
      },
      {
        id: "windsurf",
        name: "Windsurf",
        enabled: Boolean(worktreePath) && (availableEditors?.windsurf ?? true),
      },
      {
        id: "finder",
        name: "Finder",
        enabled: Boolean(worktreePath) && (availableEditors?.finder ?? true),
      },
      {
        id: "iterm",
        name: "iTerm",
        enabled: Boolean(worktreePath) && (availableEditors?.iterm ?? false),
      },
      {
        id: "terminal",
        name: "Terminal",
        enabled: Boolean(worktreePath) && (availableEditors?.terminal ?? false),
      },
      {
        id: "ghostty",
        name: "Ghostty",
        enabled: Boolean(worktreePath) && (availableEditors?.ghostty ?? false),
      },
      {
        id: "alacritty",
        name: "Alacritty",
        enabled: Boolean(worktreePath) && (availableEditors?.alacritty ?? false),
      },
      {
        id: "xcode",
        name: "Xcode",
        enabled: Boolean(worktreePath) && (availableEditors?.xcode ?? false),
      },
    ];

    return baseItems
      .filter((item) => item.enabled)
      .map((item) => ({
        id: item.id,
        name: item.name,
        Icon: editorIcons[item.id] ?? null,
      }));
  }, [availableEditors, vscodeUrl, worktreePath]);

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
