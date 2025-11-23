import { useExpandTasks } from "@/contexts/expand-tasks/ExpandTasksContext";
import { useSocket } from "@/contexts/socket/use-socket";
import { useTheme } from "@/components/theme/use-theme";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import type {
  CreateLocalWorkspaceResponse,
  CreateCloudWorkspaceResponse,
} from "@cmux/shared";
import { useMutation } from "convex/react";
import { Server as ServerIcon, FolderOpen, Loader2 } from "lucide-react";
import { useCallback, useState } from "react";
import { toast } from "sonner";

type WorkspaceCreationButtonsProps = {
  teamSlugOrId: string;
  selectedProject: string[];
  isEnvSelected: boolean;
};

export function WorkspaceCreationButtons({
  teamSlugOrId,
  selectedProject,
  isEnvSelected,
}: WorkspaceCreationButtonsProps) {
  const { socket } = useSocket();
  const { addTaskToExpand } = useExpandTasks();
  const { theme } = useTheme();
  const [isCreatingLocal, setIsCreatingLocal] = useState(false);
  const [isCreatingCloud, setIsCreatingCloud] = useState(false);

  const reserveLocalWorkspace = useMutation(api.localWorkspaces.reserve);
  const createTask = useMutation(api.tasks.create);

  const handleCreateLocalWorkspace = useCallback(async () => {
    if (!socket) {
      toast.error("Socket not connected");
      return;
    }

    if (selectedProject.length === 0) {
      toast.error("Please select a repository first");
      return;
    }

    if (isEnvSelected) {
      toast.error("Local workspaces require a repository, not an environment");
      return;
    }

    const projectFullName = selectedProject[0];
    const repoUrl = `https://github.com/${projectFullName}.git`;

    setIsCreatingLocal(true);

    try {
      const reservation = await reserveLocalWorkspace({
        teamSlugOrId,
        projectFullName,
        repoUrl,
      });

      if (!reservation) {
        throw new Error("Unable to reserve workspace name");
      }

      addTaskToExpand(reservation.taskId);

      await new Promise<void>((resolve) => {
        socket.emit(
          "create-local-workspace",
          {
            teamSlugOrId,
            projectFullName,
            repoUrl,
            taskId: reservation.taskId,
            taskRunId: reservation.taskRunId,
            workspaceName: reservation.workspaceName,
            descriptor: reservation.descriptor,
          },
          async (response: CreateLocalWorkspaceResponse) => {
            if (response.success) {
              toast.success(
                `Local workspace "${reservation.workspaceName}" created successfully`
              );
            } else {
              toast.error(
                response.error || "Failed to create local workspace"
              );
            }
            resolve();
          }
        );
      });
    } catch (error) {
      console.error("Error creating local workspace:", error);
      toast.error("Failed to create local workspace");
    } finally {
      setIsCreatingLocal(false);
    }
  }, [
    socket,
    selectedProject,
    isEnvSelected,
    teamSlugOrId,
    reserveLocalWorkspace,
    addTaskToExpand,
  ]);

  const handleCreateCloudWorkspace = useCallback(async () => {
    if (!socket) {
      toast.error("Socket not connected");
      return;
    }

    if (selectedProject.length === 0) {
      toast.error("Please select a repository or environment first");
      return;
    }

    const projectFullName = selectedProject[0];

    setIsCreatingCloud(true);

    try {
      // Check if it's an environment or repository
      if (isEnvSelected) {
        // Environment-based cloud workspace
        const environmentId = projectFullName.replace(
          /^env:/,
          ""
        ) as Id<"environments">;

        // Extract environment name from the selectedProject (format is "env:id:name")
        const environmentName = projectFullName.split(":")[2] || "Unknown Environment";

        // Create task in Convex with environment name
        const taskId = await createTask({
          teamSlugOrId,
          text: `Cloud Workspace: ${environmentName}`,
          projectFullName: undefined, // No repo for cloud environment workspaces
          baseBranch: undefined, // No branch for environments
          environmentId,
          isCloudWorkspace: true,
        });

        // Hint the sidebar to auto-expand this task once it appears
        addTaskToExpand(taskId);

        await new Promise<void>((resolve) => {
          socket.emit(
            "create-cloud-workspace",
            {
              teamSlugOrId,
              environmentId,
              taskId,
              theme,
            },
            async (response: CreateCloudWorkspaceResponse) => {
              if (response.success) {
                toast.success("Cloud workspace created successfully");
              } else {
                toast.error(
                  response.error || "Failed to create cloud workspace"
                );
              }
              resolve();
            }
          );
        });
      } else {
        // Repository-based cloud workspace
        const repoUrl = `https://github.com/${projectFullName}.git`;

        // Create task in Convex for repo-based cloud workspace
        const taskId = await createTask({
          teamSlugOrId,
          text: `Cloud Workspace: ${projectFullName}`,
          projectFullName,
          baseBranch: undefined,
          environmentId: undefined, // No environment for repo-based cloud workspaces
          isCloudWorkspace: true,
        });

        // Hint the sidebar to auto-expand this task once it appears
        addTaskToExpand(taskId);

        await new Promise<void>((resolve) => {
          socket.emit(
            "create-cloud-workspace",
            {
              teamSlugOrId,
              projectFullName,
              repoUrl,
              taskId,
              theme,
            },
            async (response: CreateCloudWorkspaceResponse) => {
              if (response.success) {
                toast.success("Cloud workspace created successfully");
              } else {
                toast.error(
                  response.error || "Failed to create cloud workspace"
                );
              }
              resolve();
            }
          );
        });
      }

      console.log("Cloud workspace created");
    } catch (error) {
      console.error("Error creating cloud workspace:", error);
      toast.error("Failed to create cloud workspace");
    } finally {
      setIsCreatingCloud(false);
    }
  }, [
    socket,
    selectedProject,
    isEnvSelected,
    teamSlugOrId,
    createTask,
    addTaskToExpand,
    theme,
  ]);

  const canCreateLocal = selectedProject.length > 0 && !isEnvSelected;
  const canCreateCloud = selectedProject.length > 0;

  const SHOW_WORKSPACE_BUTTONS = true;

  if (!SHOW_WORKSPACE_BUTTONS) {
    return null;
  }

  return (
    <div className="mt-2 mb-2">
      <div className="flex items-start gap-3 px-2">
        {/* Local Workspace */}
        <div className="flex-1">
          <div className="flex flex-col gap-1">
            <div className="flex items-center gap-1.5">
              <FolderOpen className="w-3.5 h-3.5 text-neutral-500 dark:text-neutral-400" />
              <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
                Local Workspace
              </span>
            </div>
            <p className="text-[11px] text-neutral-600 dark:text-neutral-400 leading-relaxed">
              Run on your machine with full control. Best for testing, debugging, or existing local environments.
            </p>
            <button
              onClick={handleCreateLocalWorkspace}
              disabled={!canCreateLocal || isCreatingLocal}
              className={`mt-1 inline-flex items-center justify-center gap-1.5 rounded-md border px-2 py-1 text-[11px] font-medium transition-colors ${
                canCreateLocal
                  ? "border-neutral-200 bg-white text-neutral-700 hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-100 dark:hover:bg-neutral-800"
                  : "border-neutral-200/50 bg-neutral-100/50 text-neutral-400 cursor-not-allowed dark:border-neutral-800/50 dark:bg-neutral-900/30 dark:text-neutral-600"
              }`}
            >
              {isCreatingLocal ? (
                <>
                  <Loader2 className="w-3 h-3 animate-spin" />
                  <span>Creating...</span>
                </>
              ) : (
                <>
                  <FolderOpen className="w-3 h-3" />
                  <span>Add Local Workspace</span>
                </>
              )}
            </button>
            {!canCreateLocal && (
              <p className="mt-1 text-[11px] text-neutral-500 dark:text-neutral-600">
                Select a repository first
              </p>
            )}
          </div>
        </div>

        {/* Cloud Workspace */}
        <div className="flex-1">
          <div className="flex flex-col gap-1">
            <div className="flex items-center gap-1.5">
              <ServerIcon className="w-3.5 h-3.5 text-neutral-500 dark:text-neutral-400" />
              <span className="text-xs font-medium text-neutral-700 dark:text-neutral-300">
                Cloud Workspace
              </span>
            </div>
            <p className="text-[11px] text-neutral-600 dark:text-neutral-400 leading-relaxed">
              Instant setup with pre-configured environments. Perfect for consistent development with pre-installed packages.
            </p>
            <button
              onClick={handleCreateCloudWorkspace}
              disabled={!canCreateCloud || isCreatingCloud}
              className={`mt-1 inline-flex items-center justify-center gap-1.5 rounded-md border px-2 py-1 text-[11px] font-medium transition-colors ${
                canCreateCloud
                  ? "border-neutral-200 bg-white text-neutral-700 hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-100 dark:hover:bg-neutral-800"
                  : "border-neutral-200/50 bg-neutral-100/50 text-neutral-400 cursor-not-allowed dark:border-neutral-800/50 dark:bg-neutral-900/30 dark:text-neutral-600"
              }`}
            >
              {isCreatingCloud ? (
                <>
                  <Loader2 className="w-3 h-3 animate-spin" />
                  <span>Creating...</span>
                </>
              ) : (
                <>
                  <ServerIcon className="w-3 h-3" />
                  <span>Add Cloud Workspace</span>
                </>
              )}
            </button>
            {!canCreateCloud && (
              <p className="mt-1 text-[11px] text-neutral-500 dark:text-neutral-600">
                Select a repository or environment first
              </p>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
