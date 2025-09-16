import {
  DashboardInput,
  type EditorApi,
} from "@/components/dashboard/DashboardInput";
import { DashboardInputControls } from "@/components/dashboard/DashboardInputControls";
import { DashboardInputFooter } from "@/components/dashboard/DashboardInputFooter";
import { DashboardStartTaskButton } from "@/components/dashboard/DashboardStartTaskButton";
import { TaskList } from "@/components/dashboard/TaskList";
import { FloatingPane } from "@/components/floating-pane";
import { GitHubIcon } from "@/components/icons/github";
import { ProviderStatusPills } from "@/components/provider-status-pills";
import { useTheme } from "@/components/theme/use-theme";
import { TitleBar } from "@/components/TitleBar";
import type { SelectOption } from "@/components/ui/searchable-select";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { useExpandTasks } from "@/contexts/expand-tasks/ExpandTasksContext";
import { useSocket } from "@/contexts/socket/use-socket";
import { createFakeConvexId } from "@/lib/fakeConvexId";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import { convexQuery } from "@convex-dev/react-query";
import { useQuery } from "@tanstack/react-query";
import { branchesQueryOptions } from "@/queries/branches";
import { createFileRoute } from "@tanstack/react-router";
import clsx from "clsx";
import { useMutation } from "convex/react";
import { Server as ServerIcon } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";

export const Route = createFileRoute("/_layout/$teamSlugOrId/dashboard")({
  component: DashboardComponent,
});

function DashboardComponent() {
  const { teamSlugOrId } = Route.useParams();
  const searchParams = Route.useSearch() as { environmentId?: string };
  const { socket } = useSocket();
  const { theme } = useTheme();
  const { addTaskToExpand } = useExpandTasks();

  const [selectedProject, setSelectedProject] = useState<string[]>(() => {
    const stored = localStorage.getItem("selectedProject");
    return stored ? JSON.parse(stored) : [];
  });
  const [selectedBranch, setSelectedBranch] = useState<string[]>([]);
  const [selectedAgents, setSelectedAgents] = useState<string[]>(() => {
    const stored = localStorage.getItem("selectedAgents");
    return stored ? JSON.parse(stored) : ["claude/opus-4.1", "codex/gpt-5"];
  });
  const [taskDescription, setTaskDescription] = useState<string>("");
  const [isCloudMode, setIsCloudMode] = useState<boolean>(() => {
    const stored = localStorage.getItem("isCloudMode");
    return stored ? JSON.parse(stored) : false;
  });

  // State for loading states
  const [isLoadingBranches, setIsLoadingBranches] = useState(false);
  const [dockerReady, setDockerReady] = useState<boolean | null>(null);

  // Ref to access editor API
  const editorApiRef = useRef<EditorApi | null>(null);

  // Preselect environment if provided in URL search params
  useEffect(() => {
    if (searchParams?.environmentId) {
      const val = `env:${searchParams.environmentId}`;
      setSelectedProject([val]);
      localStorage.setItem("selectedProject", JSON.stringify([val]));
      setIsCloudMode(true);
      localStorage.setItem("isCloudMode", JSON.stringify(true));
    }
  }, [searchParams?.environmentId]);

  // Callback for task description changes
  const handleTaskDescriptionChange = useCallback((value: string) => {
    setTaskDescription(value);
  }, []);

  // Fetch branches for selected repo from Convex
  const isEnvSelected = useMemo(
    () => (selectedProject[0] || "").startsWith("env:"),
    [selectedProject]
  );

  const branchesQuery = useQuery(
    branchesQueryOptions({
      teamSlugOrId,
      repoFullName: selectedProject[0] || "",
    })
  );
  const branches = useMemo(
    () => branchesQuery.data || [],
    [branchesQuery.data]
  );

  const fetchBranches = useCallback((_repo?: string) => {
    setIsLoadingBranches(true);
    branchesQuery
      .refetch()
      .finally(() => setIsLoadingBranches(false))
      .catch(() => setIsLoadingBranches(false));
  }, [branchesQuery]);

  // Callback for project selection changes
  const handleProjectChange = useCallback(
    (newProjects: string[]) => {
      setSelectedProject(newProjects);
      localStorage.setItem("selectedProject", JSON.stringify(newProjects));
      if (newProjects[0] !== selectedProject[0]) {
        setSelectedBranch([]);
      }
      // If selecting an environment, enforce cloud mode
      if ((newProjects[0] || "").startsWith("env:")) {
        setIsCloudMode(true);
        localStorage.setItem("isCloudMode", JSON.stringify(true));
      } else {
        void fetchBranches(newProjects[0]);
      }
    },
    [selectedProject, fetchBranches]
  );

  // Callback for branch selection changes
  const handleBranchChange = useCallback((newBranches: string[]) => {
    setSelectedBranch(newBranches);
  }, []);

  // Callback for agent selection changes
  const handleAgentChange = useCallback((newAgents: string[]) => {
    setSelectedAgents(newAgents);
    localStorage.setItem("selectedAgents", JSON.stringify(newAgents));
  }, []);

  // Fetch repos from Convex
  const reposByOrgQuery = useQuery({
    ...convexQuery(api.github.getReposByOrg, { teamSlugOrId }),
    refetchOnMount: "always",
    refetchOnWindowFocus: false,
  });
  const reposByOrg = useMemo(
    () => reposByOrgQuery.data || {},
    [reposByOrgQuery.data]
  );

  // Trigger GitHub refresh if repos are empty
  useEffect(() => {
    if (!socket || !reposByOrgQuery.isSuccess) return;
    
    // If query succeeded but returned empty repos, trigger a GitHub refresh
    const hasRepos = Object.keys(reposByOrg).length > 0;
    if (!hasRepos) {
      console.log("[Dashboard] No repos found, triggering GitHub refresh");
      socket.emit("github-fetch-repos", { teamSlugOrId }, (response) => {
        if (response?.success) {
          console.log("[Dashboard] GitHub refresh triggered successfully");
          // The query will automatically update when new repos are added to Convex
        } else {
          console.error("[Dashboard] GitHub refresh failed:", response?.error);
        }
      });
    }
  }, [socket, reposByOrgQuery.isSuccess, reposByOrg, teamSlugOrId]);

  // Socket-based functions to fetch data from GitHub
  // Removed unused fetchRepos function - functionality is handled by Convex queries

  const checkProviderStatus = useCallback(() => {
    if (!socket) return;

    socket.emit("check-provider-status", (response) => {
      if (!response?.success) return;
      const isRunning = response.dockerStatus?.isRunning;
      if (typeof isRunning === "boolean") {
        setDockerReady(isRunning);
      }
    });
  }, [socket]);

  // Mutation to create tasks with optimistic update
  const createTask = useMutation(api.tasks.create).withOptimisticUpdate(
    (localStore, args) => {
      const currentTasks = localStore.getQuery(api.tasks.get, {
        teamSlugOrId,
      });

      if (currentTasks !== undefined) {
        const now = Date.now();
        const optimisticTask = {
          _id: createFakeConvexId() as Doc<"tasks">["_id"],
          _creationTime: now,
          text: args.text,
          description: args.description,
          projectFullName: args.projectFullName,
          baseBranch: args.baseBranch,
          worktreePath: args.worktreePath,
          isCompleted: false,
          isArchived: false,
          createdAt: now,
          updatedAt: now,
          images: args.images,
          userId: "optimistic",
          teamId: teamSlugOrId,
        };

        // Add the new task at the beginning (since we order by desc)
        const listArgs: {
          teamSlugOrId: string;
          projectFullName?: string;
          archived?: boolean;
        } = {
          teamSlugOrId,
        };
        localStore.setQuery(api.tasks.get, listArgs, [
          optimisticTask,
          ...currentTasks,
        ]);
      }
    }
  );
  const generateUploadUrl = useMutation(api.storage.generateUploadUrl);

  const effectiveSelectedBranch = useMemo(
    () =>
      selectedBranch.length > 0
        ? selectedBranch
        : branches && branches.length > 0
          ? [
              branches.includes("main")
                ? "main"
                : branches.includes("master")
                  ? "master"
                  : branches[0],
            ]
          : [],
    [selectedBranch, branches]
  );

  const handleStartTask = useCallback(async () => {
    // For local mode, perform a fresh docker check right before starting
    if (!isEnvSelected && !isCloudMode) {
      let ready = dockerReady;
      if (!ready && socket) {
        ready = await new Promise<boolean>((resolve) => {
          socket.emit("check-provider-status", (response) => {
            const isRunning = !!response?.dockerStatus?.isRunning;
            if (typeof isRunning === "boolean") {
              setDockerReady(isRunning);
            }
            resolve(isRunning);
          });
        });
      }
      if (!ready) {
        toast.error("Docker is not running. Start Docker Desktop.");
        return;
      }
    }

    if (!selectedProject[0] || !taskDescription.trim()) {
      console.error("Please select a project and enter a task description");
      return;
    }
    if (!socket) {
      console.error("Socket not connected");
      return;
    }

    // Use the effective selected branch (respects available branches and sensible defaults)
    const branch = effectiveSelectedBranch[0];
    const projectFullName = selectedProject[0];
    const envSelected = projectFullName.startsWith("env:");

    try {
      // Extract content including images from the editor
      const content = editorApiRef.current?.getContent();
      const images = content?.images || [];

      // Upload images to Convex storage first
      const uploadedImages = await Promise.all(
        images.map(
          async (image: {
            src: string;
            fileName?: string;
            altText: string;
          }) => {
            // Convert base64 to blob
            const base64Data = image.src.split(",")[1] || image.src;
            const byteCharacters = atob(base64Data);
            const byteNumbers = new Array(byteCharacters.length);
            for (let i = 0; i < byteCharacters.length; i++) {
              byteNumbers[i] = byteCharacters.charCodeAt(i);
            }
            const byteArray = new Uint8Array(byteNumbers);
            const blob = new Blob([byteArray], { type: "image/png" });
            const uploadUrl = await generateUploadUrl({
              teamSlugOrId,
            });
            const result = await fetch(uploadUrl, {
              method: "POST",
              headers: { "Content-Type": blob.type },
              body: blob,
            });
            const { storageId } = await result.json();

            return {
              storageId,
              fileName: image.fileName,
              altText: image.altText,
            };
          }
        )
      );

      // Clear input after successful task creation
      setTaskDescription("");
      // Force editor to clear
      handleTaskDescriptionChange("");
      if (editorApiRef.current?.clear) {
        editorApiRef.current.clear();
      }

      // Create task in Convex with storage IDs
      const taskId = await createTask({
        teamSlugOrId,
        text: content?.text || taskDescription, // Use content.text which includes image references
        projectFullName: envSelected ? undefined : projectFullName,
        baseBranch: envSelected ? undefined : branch,
        images: uploadedImages.length > 0 ? uploadedImages : undefined,
      });

      // Hint the sidebar to auto-expand this task once it appears
      addTaskToExpand(taskId);

      const repoUrl = envSelected
        ? undefined
        : `https://github.com/${projectFullName}.git`;

      // For socket.io, we need to send the content text (which includes image references) and the images
      socket.emit(
        "start-task",
        {
          ...(repoUrl ? { repoUrl } : {}),
          ...(envSelected ? {} : { branch }),
          taskDescription: content?.text || taskDescription, // Use content.text which includes image references
          projectFullName,
          taskId,
          selectedAgents:
            selectedAgents.length > 0 ? selectedAgents : undefined,
          isCloudMode: envSelected ? true : isCloudMode,
          ...(envSelected
            ? {
                environmentId: projectFullName.replace(
                  /^env:/,
                  ""
                ) as string & {
                  __tableName: "environments";
                },
              }
            : {}),
          images: images.length > 0 ? images : undefined,
          theme,
        },
        (response) => {
          if ("error" in response) {
            console.error("Task start error:", response.error);
            toast.error(`Task start error: ${response.error}`);
          } else {
            console.log("Task started:", response);
          }
        }
      );
      console.log("Task created:", taskId);
    } catch (error) {
      console.error("Error starting task:", error);
    }
  }, [
    selectedProject,
    taskDescription,
    socket,
    effectiveSelectedBranch,
    handleTaskDescriptionChange,
    createTask,
    teamSlugOrId,
    addTaskToExpand,
    selectedAgents,
    isCloudMode,
    isEnvSelected,
    dockerReady,
    theme,
    generateUploadUrl,
  ]);

  // Fetch repos on mount if none exist
  // useEffect(() => {
  //   if (Object.keys(reposByOrg).length === 0) {
  //     fetchRepos();
  //   }
  // }, [reposByOrg, fetchRepos]);

  // Check provider status on mount and keep it fresh without page refresh
  useEffect(() => {
    // Initial check
    checkProviderStatus();

    // Poll while the dashboard is open so Docker state updates live
    const interval = setInterval(() => {
      checkProviderStatus();
    }, 5000);

    // Also refresh on window focus to catch recent changes quickly
    const handleFocus = () => checkProviderStatus();
    window.addEventListener("focus", handleFocus);

    return () => {
      clearInterval(interval);
      window.removeEventListener("focus", handleFocus);
    };
  }, [checkProviderStatus]);

  // Fetch branches when repo changes
  // const selectedRepo = selectedProject[0];
  // useEffect(() => {
  //   if (
  //     selectedRepo &&
  //     !selectedRepo.startsWith("env:") &&
  //     branches.length === 0
  //   ) {
  //     fetchBranches(selectedRepo);
  //   }
  // }, [selectedRepo, branches, fetchBranches]);

  // Format repos for multiselect
  // Fetch environments
  const environmentsQuery = useQuery(
    convexQuery(api.environments.list, { teamSlugOrId })
  );

  const projectOptions = useMemo(() => {
    // Repo options as objects with GitHub icon
    const repoValues = Array.from(
      new Set(
        Object.entries(reposByOrg || {}).flatMap(([, repos]) =>
          repos.map((repo) => repo.fullName)
        )
      )
    );
    const repoOptions = repoValues.map((fullName) => ({
      label: fullName,
      value: fullName,
      icon: (
        <GitHubIcon className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
      ),
      iconKey: "github",
    }));

    // Environment options as objects with an icon and stable key
    const envOptions = (environmentsQuery.data || []).map((env) => ({
      label: `${env.name}`,
      value: `env:${env._id}`,
      icon: (
        <Tooltip>
          <TooltipTrigger asChild>
            <span>
              <ServerIcon className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
            </span>
          </TooltipTrigger>
          <TooltipContent>Environment: {env.name}</TooltipContent>
        </Tooltip>
      ),
      iconKey: "environment",
    }));

    const options: SelectOption[] = [];
    if (envOptions.length > 0) {
      options.push({
        label: "Environments",
        value: "__heading-env",
        heading: true,
      });
      options.push(...envOptions);
    }
    if (repoOptions.length > 0) {
      options.push({
        label: "Repositories",
        value: "__heading-repo",
        heading: true,
      });
      options.push(...repoOptions);
    }

    return options;
  }, [reposByOrg, environmentsQuery.data]);

  const branchOptions = branches || [];

  // Cloud mode toggle handler
  const handleCloudModeToggle = useCallback(() => {
    if (isEnvSelected) return; // environment forces cloud mode
    const newMode = !isCloudMode;
    setIsCloudMode(newMode);
    localStorage.setItem("isCloudMode", JSON.stringify(newMode));
  }, [isCloudMode, isEnvSelected]);

  // Listen for VSCode spawned events
  useEffect(() => {
    if (!socket) return;

    const handleVSCodeSpawned = (data: {
      instanceId: string;
      url: string;
      workspaceUrl: string;
      provider: string;
    }) => {
      console.log("VSCode spawned:", data);
      // Open in new tab
      // window.open(data.workspaceUrl, "_blank");
    };

    socket.on("vscode-spawned", handleVSCodeSpawned);

    return () => {
      socket.off("vscode-spawned", handleVSCodeSpawned);
    };
  }, [socket]);

  // Listen for default repo from CLI
  useEffect(() => {
    if (!socket) return;

    const handleDefaultRepo = (data: {
      repoFullName: string;
      branch?: string;
      localPath: string;
    }) => {
      // Always set the selected project when a default repo is provided
      // This ensures CLI-provided repos take precedence
      setSelectedProject([data.repoFullName]);
      localStorage.setItem(
        "selectedProject",
        JSON.stringify([data.repoFullName])
      );

      // Set the selected branch
      if (data.branch) {
        setSelectedBranch([data.branch]);
      }
    };

    socket.on("default-repo", handleDefaultRepo);

    return () => {
      socket.off("default-repo", handleDefaultRepo);
    };
  }, [socket]);

  // Global keydown handler for autofocus
  useEffect(() => {
    const handleGlobalKeyDown = (e: KeyboardEvent) => {
      // Skip if already focused on an input, textarea, or contenteditable that's NOT the editor
      const activeElement = document.activeElement;
      const isEditor =
        activeElement?.getAttribute("data-cmux-input") === "true";
      const isCommentInput = activeElement?.id === "cmux-comments-root";
      if (
        !isEditor &&
        (activeElement?.tagName === "INPUT" ||
          activeElement?.tagName === "TEXTAREA" ||
          activeElement?.getAttribute("contenteditable") === "true" ||
          activeElement?.closest('[contenteditable="true"]') ||
          isCommentInput)
      ) {
        return;
      }

      // Skip for modifier keys and special keys
      if (
        e.ctrlKey ||
        e.metaKey ||
        e.altKey ||
        e.key === "Tab" ||
        e.key === "Escape" ||
        e.key === "Enter" ||
        e.key.startsWith("F") || // Function keys
        e.key.startsWith("Arrow") ||
        e.key === "Home" ||
        e.key === "End" ||
        e.key === "PageUp" ||
        e.key === "PageDown" ||
        e.key === "Delete" ||
        e.key === "Backspace" ||
        e.key === "CapsLock" ||
        e.key === "Control" ||
        e.key === "Shift" ||
        e.key === "Alt" ||
        e.key === "Meta" ||
        e.key === "ContextMenu"
      ) {
        return;
      }

      // Check if it's a printable character (including shift for uppercase)
      if (e.key.length === 1) {
        // Prevent default to avoid duplicate input
        e.preventDefault();

        // Focus the editor and insert the character
        if (editorApiRef.current?.focus) {
          editorApiRef.current.focus();

          // Insert the typed character
          if (editorApiRef.current.insertText) {
            editorApiRef.current.insertText(e.key);
          }
        }
      }
    };

    document.addEventListener("keydown", handleGlobalKeyDown);

    return () => {
      document.removeEventListener("keydown", handleGlobalKeyDown);
    };
  }, []);

  // Do not pre-disable UI on Docker status; handle fresh check on submit

  // Handle Command+Enter keyboard shortcut
  const handleSubmit = useCallback(() => {
    if (selectedProject[0] && taskDescription.trim()) {
      void handleStartTask();
    }
  }, [selectedProject, taskDescription, handleStartTask]);

  // Memoized computed values for editor props
  const lexicalRepoUrl = useMemo(() => {
    if (!selectedProject[0]) return undefined;
    if (isEnvSelected) return undefined;
    return `https://github.com/${selectedProject[0]}.git`;
  }, [selectedProject, isEnvSelected]);

  const lexicalBranch = useMemo(
    () => effectiveSelectedBranch[0],
    [effectiveSelectedBranch]
  );

  const canSubmit = useMemo(() => {
    if (!selectedProject[0]) return false;
    if (!taskDescription.trim()) return false;
    if (selectedAgents.length === 0) return false;
    if (isEnvSelected) return true; // no branch required when environment selected
    return !!effectiveSelectedBranch[0];
  }, [
    selectedProject,
    taskDescription,
    selectedAgents,
    isEnvSelected,
    effectiveSelectedBranch,
  ]);

  return (
    <FloatingPane header={<TitleBar title="cmux" />}>
      <div className="flex flex-col grow overflow-y-auto">
        {/* Main content area */}
        <div className="flex-1 flex justify-center px-4 pt-60 pb-4">
          <div className="w-full max-w-4xl min-w-0">
            <div
              className={clsx(
                "relative bg-white dark:bg-neutral-700/50 border border-neutral-200 dark:border-neutral-500/15 rounded-2xl transition-all"
              )}
            >
              {/* Provider Status Pills */}
              <ProviderStatusPills teamSlugOrId={teamSlugOrId} />

              {/* Editor Input */}
              <DashboardInput
                ref={editorApiRef}
                onTaskDescriptionChange={handleTaskDescriptionChange}
                onSubmit={handleSubmit}
                repoUrl={lexicalRepoUrl}
                branch={lexicalBranch}
                persistenceKey="dashboard-task-description"
                maxHeight="300px"
              />

              {/* Bottom bar: controls + submit button */}
              <DashboardInputFooter>
                <DashboardInputControls
                  projectOptions={projectOptions}
                  selectedProject={selectedProject}
                  onProjectChange={handleProjectChange}
                  branchOptions={branchOptions}
                  selectedBranch={effectiveSelectedBranch}
                  onBranchChange={handleBranchChange}
                  selectedAgents={selectedAgents}
                  onAgentChange={handleAgentChange}
                  isCloudMode={isCloudMode}
                  onCloudModeToggle={handleCloudModeToggle}
                  isLoadingProjects={reposByOrgQuery.isLoading}
                  isLoadingBranches={
                    isLoadingBranches || branchesQuery.isLoading
                  }
                  teamSlugOrId={teamSlugOrId}
                  cloudToggleDisabled={isEnvSelected}
                  branchDisabled={isEnvSelected}
                />
                <DashboardStartTaskButton
                  canSubmit={canSubmit}
                  onStartTask={handleStartTask}
                />
              </DashboardInputFooter>
            </div>

            {/* Task List */}
            <TaskList teamSlugOrId={teamSlugOrId} />
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}
