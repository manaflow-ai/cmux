import { env } from "@/client-env";
import {
  DashboardInput,
  type EditorApi,
} from "@/components/dashboard/DashboardInput";
import { DashboardInputControls } from "@/components/dashboard/DashboardInputControls";
import { DashboardInputFooter } from "@/components/dashboard/DashboardInputFooter";
import { DashboardStartTaskButton } from "@/components/dashboard/DashboardStartTaskButton";
import { TaskList } from "@/components/dashboard/TaskList";
import { WorkspaceCreationButtons } from "@/components/dashboard/WorkspaceCreationButtons";
import { FloatingPane } from "@/components/floating-pane";
import { WorkspaceSetupPanel } from "@/components/WorkspaceSetupPanel";
import { GitHubIcon } from "@/components/icons/github";
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
import { attachTaskLifecycleListeners } from "@/lib/socket/taskLifecycleListeners";
import { getApiIntegrationsGithubBranchesOptions } from "@/queries/branches";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { api } from "@cmux/convex/api";
import type { Doc, Id } from "@cmux/convex/dataModel";
import type {
  ProviderStatusResponse,
  TaskAcknowledged,
  TaskError,
  TaskStarted,
} from "@cmux/shared";
import { AGENT_CONFIGS } from "@cmux/shared/agentConfig";
import { convexQuery } from "@convex-dev/react-query";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useAction, useMutation } from "convex/react";
import { Server as ServerIcon } from "lucide-react";
import { useDebouncedValue } from "@mantine/hooks";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import { z } from "zod";
import { typedZid } from "@cmux/shared/utils/typed-zid";

export const Route = createFileRoute("/_layout/$teamSlugOrId/dashboard")({
  component: DashboardComponent,
  loader: async (opts) => {
    const { teamSlugOrId } = opts.params;
    // Prewarm queries used in the dashboard
    convexQueryClient.convexClient.prewarmQuery({
      query: api.github.getReposByOrg,
      args: { teamSlugOrId },
    });
    convexQueryClient.convexClient.prewarmQuery({
      query: api.environments.list,
      args: { teamSlugOrId },
    });
    // Prewarm queries used in TaskList
    convexQueryClient.convexClient.prewarmQuery({
      query: api.tasks.get,
      args: { teamSlugOrId },
    });
  },
});

// Default agents (not persisted to localStorage)
const DEFAULT_AGENTS = ["claude/opus-4.5"];
const KNOWN_AGENT_NAMES = new Set(AGENT_CONFIGS.map((agent) => agent.name));
const DISABLED_AGENT_NAMES = new Set(
  AGENT_CONFIGS.filter((agent) => agent.disabled).map((agent) => agent.name)
);
const DEFAULT_AGENT_SELECTION = DEFAULT_AGENTS.filter(
  (agent) => KNOWN_AGENT_NAMES.has(agent) && !DISABLED_AGENT_NAMES.has(agent)
);

const AGENT_SELECTION_SCHEMA = z.array(z.string());

// Filter to known agents and exclude disabled ones
const filterKnownAgents = (agents: string[]): string[] =>
  agents.filter(
    (agent) => KNOWN_AGENT_NAMES.has(agent) && !DISABLED_AGENT_NAMES.has(agent)
  );

const parseStoredAgentSelection = (stored: string | null): string[] => {
  if (!stored) {
    return [];
  }

  try {
    const parsed = JSON.parse(stored);
    const result = AGENT_SELECTION_SCHEMA.safeParse(parsed);
    if (!result.success) {
      console.warn("Invalid stored agent selection", result.error);
      return [];
    }

    return filterKnownAgents(result.data);
  } catch (error) {
    console.warn("Failed to parse stored agent selection", error);
    return [];
  }
};

function DashboardComponent() {
  const { teamSlugOrId } = Route.useParams();
  const searchParams = Route.useSearch() as { environmentId?: string };
  const { socket } = useSocket();
  const { theme } = useTheme();
  const { addTaskToExpand } = useExpandTasks();

  const [selectedProject, setSelectedProject] = useState<string[]>(() => {
    const stored = localStorage.getItem(`selectedProject-${teamSlugOrId}`);
    return stored ? JSON.parse(stored) : [];
  });
  const [selectedBranch, setSelectedBranch] = useState<string[]>([]);

  const [selectedAgents, setSelectedAgentsState] = useState<string[]>(() => {
    const storedAgents = parseStoredAgentSelection(
      localStorage.getItem("selectedAgents")
    );

    if (storedAgents.length > 0) {
      return storedAgents;
    }

    return DEFAULT_AGENT_SELECTION.length > 0
      ? [...DEFAULT_AGENT_SELECTION]
      : [];
  });
  const selectedAgentsRef = useRef<string[]>(selectedAgents);

  const setSelectedAgents = useCallback(
    (agents: string[]) => {
      selectedAgentsRef.current = agents;
      setSelectedAgentsState(agents);
    },
    [setSelectedAgentsState]
  );

  const [taskDescription, setTaskDescription] = useState<string>("");
  const [debouncedTaskDescription] = useDebouncedValue(taskDescription, 600);
  // In web mode, always force cloud mode
  const [isCloudMode, setIsCloudMode] = useState<boolean>(() => {
    if (env.NEXT_PUBLIC_WEB_MODE) return true;
    const stored = localStorage.getItem("isCloudMode");
    return stored ? JSON.parse(stored) : true;
  });

  const [, setDockerReady] = useState<boolean | null>(null);
  const [providerStatus, setProviderStatus] =
    useState<ProviderStatusResponse | null>(null);
  const [isStartingTask, setIsStartingTask] = useState(false);
  const isStartingTaskRef = useRef(false);

  // const [hasDismissedCloudRepoOnboarding, setHasDismissedCloudRepoOnboarding] =
  //   useState<boolean>(false);

  // Ref to access editor API
  const editorApiRef = useRef<EditorApi | null>(null);
  const prewarmKeyRef = useRef<string | null>(null);
  const prewarmPendingRef = useRef(false);

  const persistAgentSelection = useCallback((agents: string[]) => {
    try {
      const isDefaultSelection =
        DEFAULT_AGENT_SELECTION.length > 0 &&
        agents.length === DEFAULT_AGENT_SELECTION.length &&
        agents.every(
          (agent, index) => agent === DEFAULT_AGENT_SELECTION[index]
        );

      if (agents.length === 0 || isDefaultSelection) {
        localStorage.removeItem("selectedAgents");
      } else {
        localStorage.setItem("selectedAgents", JSON.stringify(agents));
      }
    } catch (error) {
      console.warn("Failed to persist agent selection", error);
    }
  }, []);

  // Preselect environment if provided in URL search params
  useEffect(() => {
    if (searchParams?.environmentId) {
      const val = `env:${searchParams.environmentId}`;
      setSelectedProject([val]);
      localStorage.setItem(
        `selectedProject-${teamSlugOrId}`,
        JSON.stringify([val])
      );
      setIsCloudMode(true);
      localStorage.setItem("isCloudMode", JSON.stringify(true));
    }
  }, [searchParams?.environmentId, teamSlugOrId]);

  // Callback for task description changes
  const handleTaskDescriptionChange = useCallback((value: string) => {
    setTaskDescription(value);
  }, []);

  // Fetch branches for selected repo
  const isEnvSelected = useMemo(
    () => (selectedProject[0] || "").startsWith("env:"),
    [selectedProject]
  );

  // Branch search state with debouncing for server-side search
  const [branchSearch, setBranchSearch] = useState("");
  const [debouncedBranchSearch] = useDebouncedValue(branchSearch, 300);

  // Immediately use empty string when cleared, otherwise use debounced value
  // This prevents delay when user clears the search
  const effectiveBranchSearch = branchSearch === "" ? "" : debouncedBranchSearch;

  // Branches query - uses GraphQL to get default branch AND branches in a single API call
  // Server-side search via GitHub GraphQL API (prefix match)
  // Each search term is cached separately by React Query
  const branchesQuery = useQuery({
    ...getApiIntegrationsGithubBranchesOptions({
      query: {
        repo: selectedProject[0] || "",
        limit: 5,
        search: effectiveBranchSearch || undefined,
      },
    }),
    staleTime: 30_000,
    enabled: !!selectedProject[0] && !isEnvSelected,
    // Keep previous data visible while fetching new search results
    // This prevents "No options" flash and button skeleton during search
    placeholderData: keepPreviousData,
  });

  // Show loading in search input when search is pending or fetching
  const isBranchSearchLoading =
    branchSearch !== "" &&
    (branchSearch !== effectiveBranchSearch || branchesQuery.isFetching);

  // Extract branch names and default branch from the query
  const branchNames = useMemo(
    () => branchesQuery.data?.branches?.map((branch) => branch.name) ?? [],
    [branchesQuery.data]
  );

  const defaultBranchName = branchesQuery.data?.defaultBranch ?? null;

  // Handle branch search changes from SearchableSelect
  const handleBranchSearchChange = useCallback((search: string) => {
    setBranchSearch(search);
  }, []);

  // Show toast if branches query fails
  useEffect(() => {
    if (branchesQuery.isError) {
      const err = branchesQuery.error;
      const message =
        err instanceof Error ? err.message : "Failed to load branches";
      toast.error("Failed to load branches", { description: message });
    }
  }, [branchesQuery.isError, branchesQuery.error]);

  // Callback for project selection changes
  const handleProjectChange = useCallback(
    (newProjects: string[]) => {
      setSelectedProject(newProjects);
      localStorage.setItem(
        `selectedProject-${teamSlugOrId}`,
        JSON.stringify(newProjects)
      );
      if (newProjects[0] !== selectedProject[0]) {
        setSelectedBranch([]);
      }
      // If selecting an environment, enforce cloud mode
      if ((newProjects[0] || "").startsWith("env:")) {
        setIsCloudMode(true);
        localStorage.setItem("isCloudMode", JSON.stringify(true));
      }
    },
    [selectedProject, teamSlugOrId]
  );

  // Callback for branch selection changes
  const handleBranchChange = useCallback((newBranches: string[]) => {
    setSelectedBranch(newBranches);
  }, []);

  // Callback for agent selection changes
  const handleAgentChange = useCallback(
    (newAgents: string[]) => {
      const normalizedAgents = filterKnownAgents(newAgents);
      setSelectedAgents(normalizedAgents);
      persistAgentSelection(normalizedAgents);
    },
    [persistAgentSelection, setSelectedAgents]
  );

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

  // Socket-based functions to fetch data from GitHub
  // Removed unused fetchRepos function - functionality is handled by Convex queries

  const checkProviderStatus = useCallback(() => {
    if (!socket) return;

    socket.emit("check-provider-status", (response) => {
      if (!response) return;
      setProviderStatus(response);

      if (response.success) {
        const isRunning = response.dockerStatus?.isRunning;
        if (typeof isRunning === "boolean") {
          setDockerReady(isRunning);
        }
      }

      const currentAgents = selectedAgentsRef.current;
      if (currentAgents.length === 0) {
        return;
      }

      const providers = response.providers;
      if (!providers || providers.length === 0) {
        const normalizedOnly = filterKnownAgents(currentAgents);
        if (normalizedOnly.length !== currentAgents.length) {
          setSelectedAgents(normalizedOnly);
          persistAgentSelection(normalizedOnly);
        }
        return;
      }

      const availableAgents = new Set(
        providers
          .filter((provider) => provider.isAvailable)
          .map((provider) => provider.name)
      );

      const normalizedAgents = filterKnownAgents(currentAgents);
      const removedUnknown = normalizedAgents.length !== currentAgents.length;

      const filteredAgents = normalizedAgents.filter((agent) =>
        availableAgents.has(agent)
      );
      const removedUnavailable = normalizedAgents.filter(
        (agent) => !availableAgents.has(agent)
      );

      if (!removedUnknown && removedUnavailable.length === 0) {
        return;
      }

      setSelectedAgents(filteredAgents);
      persistAgentSelection(filteredAgents);

      if (removedUnavailable.length > 0) {
        const uniqueMissing = Array.from(new Set(removedUnavailable));
        if (uniqueMissing.length > 0) {
          const label = uniqueMissing.length === 1 ? "model" : "models";
          const verb = uniqueMissing.length === 1 ? "is" : "are";
          const thisThese = uniqueMissing.length === 1 ? "this" : "these";
          const actionMessage = env.NEXT_PUBLIC_WEB_MODE
            ? `Add your API keys in Settings to use ${thisThese} ${label}.`
            : `Update credentials in Settings to use ${thisThese} ${label}.`;
          toast.warning(
            `${uniqueMissing.join(", ")} ${verb} not configured and was removed from the selection. ${actionMessage}`
          );
        }
      }
    });
  }, [persistAgentSelection, setDockerReady, setSelectedAgents, socket]);

  // Mutation to create tasks with optimistic update
  const createTask = useMutation(api.tasks.create).withOptimisticUpdate(
    (localStore, args) => {
      const currentTasks = localStore.getQuery(api.tasks.get, {
        teamSlugOrId,
      });

      if (currentTasks !== undefined) {
        const now = Date.now();
        const fakeTaskId = createFakeConvexId() as Doc<"tasks">["_id"];
        const optimisticTask = {
          _id: fakeTaskId,
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
          environmentId: args.environmentId,
          hasUnread: false,
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

        // Create optimistic task runs if selectedAgents provided
        if (args.selectedAgents && args.selectedAgents.length > 0) {
          const optimisticRuns = args.selectedAgents.map((agentName) => ({
            _id: createFakeConvexId() as Doc<"taskRuns">["_id"],
            _creationTime: now,
            taskId: fakeTaskId,
            prompt: args.text,
            agentName,
            status: "pending" as const,
            createdAt: now,
            updatedAt: now,
            userId: "optimistic",
            teamId: teamSlugOrId,
            environmentId: args.environmentId,
            isCloudWorkspace: args.isCloudWorkspace,
            children: [],
            environment: null,
          }));

          // Set the task runs query for this fake task
          localStore.setQuery(
            api.taskRuns.getByTask,
            { teamSlugOrId, taskId: fakeTaskId },
            optimisticRuns,
          );
        }
      }
    },
  );
  const generateUploadUrl = useMutation(api.storage.generateUploadUrl);
  const addManualRepo = useAction(api.github_http.addManualRepo);

  const effectiveSelectedBranch = useMemo(() => {
    if (selectedBranch.length > 0) {
      return selectedBranch;
    }
    // Use the default branch from the response
    if (defaultBranchName) {
      return [defaultBranchName];
    }
    // Fallback to common default branch names if query hasn't loaded yet
    if (branchNames.length === 0) {
      return [];
    }
    if (branchNames.includes("main")) {
      return ["main"];
    }
    if (branchNames.includes("master")) {
      return ["master"];
    }
    return [];
  }, [selectedBranch, defaultBranchName, branchNames]);

  const handleStartTask = useCallback(async () => {
    if (isStartingTaskRef.current) {
      return;
    }

    isStartingTaskRef.current = true;
    setIsStartingTask(true);

    try {
      // For local mode, perform a fresh docker check right before starting
      if (!isEnvSelected && !isCloudMode) {
        // Always check Docker status when in local mode, regardless of current state
        if (socket) {
          const dockerCheck = await new Promise<{
            isRunning: boolean;
            workerImage?: {
              name: string;
              isAvailable: boolean;
              isPulling?: boolean;
            };
          }>((resolve) => {
            socket.emit("check-provider-status", (response) => {
              const isRunning = !!response?.dockerStatus?.isRunning;
              if (typeof isRunning === "boolean") {
                setDockerReady(isRunning);
              }
              resolve({
                isRunning,
                workerImage: response?.dockerStatus?.workerImage,
              });
            });
          });

          // Only show the alert if Docker is actually not running after checking
          if (!dockerCheck.isRunning) {
            toast.error("Docker is not running. Start Docker Desktop.");
            return;
          }

          // Check if Docker worker image is available
          if (dockerCheck.workerImage && !dockerCheck.workerImage.isAvailable) {
            const imageName = dockerCheck.workerImage.name;
            if (dockerCheck.workerImage.isPulling) {
              toast.error(
                `Docker image "${imageName}" is currently being pulled. Please wait for it to complete.`
              );
            } else {
              toast.error(
                `Docker image "${imageName}" is not available. Please pull it first: docker pull ${imageName}`
              );
            }
            return;
          }
        } else {
          // If socket is not connected, we can't verify Docker status
          console.error("Cannot verify Docker status: socket not connected");
          toast.error(
            "Cannot verify Docker status. Please ensure the server is running."
          );
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
      const environmentId = envSelected
        ? (projectFullName.replace(/^env:/, "") as Id<"environments">)
        : undefined;

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

      // Determine which agents to spawn
      const agentsToSpawn =
        selectedAgents.length > 0 ? selectedAgents : DEFAULT_AGENTS;

      // Create task in Convex with storage IDs and task runs atomically
      // Note: isCloudWorkspace is NOT set here - that's only for standalone workspaces without agents.
      // isCloudMode (passed to socket) determines whether agents run in cloud vs local Docker.
      const { taskId, taskRunIds } = await createTask({
        teamSlugOrId,
        text: content?.text || taskDescription, // Use content.text which includes image references
        projectFullName: envSelected ? undefined : projectFullName,
        baseBranch: envSelected ? undefined : branch,
        images: uploadedImages.length > 0 ? uploadedImages : undefined,
        environmentId,
        selectedAgents: agentsToSpawn,
      });

      // Hint the sidebar to auto-expand this task once it appears
      addTaskToExpand(taskId);

      const repoUrl = envSelected
        ? undefined
        : `https://github.com/${projectFullName}.git`;

      // For socket.io, we need to send the content text (which includes image references) and the images
      const handleStartTaskAck = (
        response: TaskAcknowledged | TaskStarted | TaskError,
      ) => {
        if ("error" in response) {
          console.error("Task start error:", response.error);
          toast.error(`Task start error: ${JSON.stringify(response.error)}`);
          return;
        }

        attachTaskLifecycleListeners(socket, response.taskId, {
          onStarted: (payload) => {
            console.log("Task started:", payload);
          },
          onFailed: (payload) => {
            toast.error(`Task failed to start: ${payload.error}`);
          },
        });
        console.log("Task acknowledged:", response);
      };

      socket.emit(
        "start-task",
        {
          ...(repoUrl ? { repoUrl } : {}),
          ...(envSelected ? {} : { branch }),
          taskDescription: content?.text || taskDescription, // Use content.text which includes image references
          projectFullName,
          taskId,
          // Pass pre-created task run IDs so server doesn't need to create them
          taskRunIds,
          selectedAgents: agentsToSpawn,
          isCloudMode: envSelected ? true : isCloudMode,
          ...(environmentId ? { environmentId } : {}),
          images: images.length > 0 ? images : undefined,
          theme,
        },
        handleStartTaskAck
      );
      console.log("Task created:", taskId);
    } catch (error) {
      console.error("Error starting task:", error);
    } finally {
      isStartingTaskRef.current = false;
      setIsStartingTask(false);
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
    theme,
    generateUploadUrl,
  ]);

  useEffect(() => {
    if (!socket) {
      return;
    }
    if (!isCloudMode) {
      return;
    }

    const trimmed = debouncedTaskDescription.trim();
    if (trimmed.length === 0) {
      prewarmKeyRef.current = null;
      return;
    }

    const selection = selectedProject[0];
    if (!selection) {
      return;
    }

    const isEnv = selection.startsWith("env:");
    let environmentId: Id<"environments"> | undefined;
    let repoUrl: string | undefined;
    let branch: string | undefined;

    if (isEnv) {
      const parsed = typedZid("environments").safeParse(
        selection.replace(/^env:/, "")
      );
      if (!parsed.success) {
        return;
      }
      environmentId = parsed.data;
    } else {
      repoUrl = `https://github.com/${selection}.git`;
      branch = effectiveSelectedBranch[0];
      if (!branch) {
        return;
      }
    }

    const nextKey = environmentId
      ? `env:${environmentId}`
      : `repo:${repoUrl ?? ""}:${branch ?? ""}`;

    if (prewarmPendingRef.current || prewarmKeyRef.current === nextKey) {
      return;
    }

    prewarmPendingRef.current = true;
    socket.emit(
      "prewarm-cloud-sandbox",
      {
        teamSlugOrId,
        ...(environmentId ? { environmentId } : {}),
        ...(repoUrl ? { repoUrl } : {}),
        ...(branch ? { branch } : {}),
      },
      (response) => {
        prewarmPendingRef.current = false;
        if (response?.success) {
          prewarmKeyRef.current = nextKey;
        } else {
          prewarmKeyRef.current = null;
        }
      }
    );
  }, [
    socket,
    isCloudMode,
    debouncedTaskDescription,
    selectedProject,
    effectiveSelectedBranch,
    teamSlugOrId,
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

  // Format repos for multiselect
  // Fetch environments
  const environmentsQuery = useQuery(
    convexQuery(api.environments.list, { teamSlugOrId })
  );

  const projectOptions = useMemo(() => {
    // Repo options as objects with GitHub icon
    const repoDocs = Object.values(reposByOrg || {}).flatMap((repos) => repos);
    const uniqueRepos = repoDocs.reduce((acc, repo) => {
      const existing = acc.get(repo.fullName);
      if (!existing) {
        acc.set(repo.fullName, repo);
        return acc;
      }
      const existingActivity =
        existing.lastPushedAt ?? Number.NEGATIVE_INFINITY;
      const candidateActivity = repo.lastPushedAt ?? Number.NEGATIVE_INFINITY;
      if (candidateActivity > existingActivity) {
        acc.set(repo.fullName, repo);
      }
      return acc;
    }, new Map<string, Doc<"repos">>());
    const sortedRepos = Array.from(uniqueRepos.values()).sort((a, b) => {
      const aPushedAt = a.lastPushedAt ?? Number.NEGATIVE_INFINITY;
      const bPushedAt = b.lastPushedAt ?? Number.NEGATIVE_INFINITY;
      if (aPushedAt !== bPushedAt) {
        return bPushedAt - aPushedAt;
      }
      return a.fullName.localeCompare(b.fullName);
    });
    const repoOptions = sortedRepos.map((repo) => ({
      label: repo.fullName,
      value: repo.fullName,
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
    // Only show environments in cloud mode
    if (isCloudMode && envOptions.length > 0) {
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
  }, [reposByOrg, environmentsQuery.data, isCloudMode]);

  const selectedRepoFullName = useMemo(() => {
    if (!selectedProject[0] || isEnvSelected) return null;
    return selectedProject[0];
  }, [selectedProject, isEnvSelected]);

  const shouldShowWorkspaceSetup = !!selectedRepoFullName && !isEnvSelected;

  // const shouldShowCloudRepoOnboarding =
  //   !!selectedRepoFullName && isCloudMode && !isEnvSelected && !hasDismissedCloudRepoOnboarding;

  // const createEnvironmentSearch = useMemo(() => {
  //   if (!selectedRepoFullName) return null;
  //   return {
  //     step: "select" as const,
  //     selectedRepos: [selectedRepoFullName],
  //     instanceId: undefined,
  //     connectionLogin: undefined,
  //     repoSearch: undefined,
  //     snapshotId: undefined,
  //   };
  // }, [selectedRepoFullName]);

  // const handleStartEnvironmentSetup = useCallback(() => {
  //   setHasDismissedCloudRepoOnboarding(true);
  // }, []);

  const branchOptions = branchNames;

  // Cloud mode toggle handler
  const handleCloudModeToggle = useCallback(() => {
    // In web mode, always stay in cloud mode
    if (env.NEXT_PUBLIC_WEB_MODE) return;
    if (isEnvSelected) return; // environment forces cloud mode
    const newMode = !isCloudMode;
    setIsCloudMode(newMode);
    localStorage.setItem("isCloudMode", JSON.stringify(newMode));
  }, [isCloudMode, isEnvSelected]);

  // Handle paste of GitHub repo URL in the project search field
  const handleProjectSearchPaste = useCallback(
    async (input: string) => {
      try {
        const result = await addManualRepo({
          teamSlugOrId,
          repoUrl: input,
        });

        if (result.success) {
          // Refetch repos to get the newly added one
          await reposByOrgQuery.refetch();

          // Select the newly added repo
          setSelectedProject([result.fullName]);
          localStorage.setItem(
            `selectedProject-${teamSlugOrId}`,
            JSON.stringify([result.fullName])
          );

          toast.success(`Added ${result.fullName} to repositories`);
          return true;
        }

        return false;
      } catch (error) {
        // Only show error toast for non-validation errors
        // Validation errors mean it's not a GitHub URL, so just return false
        if (
          error instanceof Error &&
          error.message &&
          !error.message.includes("Invalid GitHub")
        ) {
          toast.error(error.message);
        }
        return false; // Don't close dropdown if it's not a valid GitHub URL
      }
    },
    [addManualRepo, teamSlugOrId, reposByOrgQuery]
  );

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
        `selectedProject-${teamSlugOrId}`,
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
  }, [socket, teamSlugOrId]);

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
  const lexicalEnvironmentId = useMemo(() => {
    if (!selectedProject[0] || !isEnvSelected) return undefined;
    return selectedProject[0].replace(/^env:/, "") as Id<"environments">;
  }, [selectedProject, isEnvSelected]);

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
      <div className="flex flex-col grow relative">
        {/* Main content area */}
        <div className="flex-1 flex flex-col pt-32 pb-0">
          <div className="w-full max-w-4xl min-w-0 mx-auto px-4">
            {/* Workspace Creation Buttons */}
            <WorkspaceCreationButtons
              teamSlugOrId={teamSlugOrId}
              selectedProject={selectedProject}
              isEnvSelected={isEnvSelected}
            />

            <DashboardMainCard
              editorApiRef={editorApiRef}
              onTaskDescriptionChange={handleTaskDescriptionChange}
              onSubmit={handleSubmit}
              lexicalRepoUrl={lexicalRepoUrl}
              lexicalEnvironmentId={lexicalEnvironmentId}
              lexicalBranch={lexicalBranch}
              projectOptions={projectOptions}
              selectedProject={selectedProject}
              onProjectChange={handleProjectChange}
              onProjectSearchPaste={handleProjectSearchPaste}
              branchOptions={branchOptions}
              selectedBranch={effectiveSelectedBranch}
              onBranchChange={handleBranchChange}
              onBranchSearchChange={handleBranchSearchChange}
              isBranchSearchLoading={isBranchSearchLoading}
              selectedAgents={selectedAgents}
              onAgentChange={handleAgentChange}
              isCloudMode={isCloudMode}
              onCloudModeToggle={handleCloudModeToggle}
              isLoadingProjects={reposByOrgQuery.isLoading}
              isLoadingBranches={branchesQuery.isFetching && effectiveSelectedBranch.length === 0}
              teamSlugOrId={teamSlugOrId}
              cloudToggleDisabled={isEnvSelected}
              branchDisabled={isEnvSelected || !selectedProject[0]}
              providerStatus={providerStatus}
              canSubmit={canSubmit}
              onStartTask={handleStartTask}
              isStartingTask={isStartingTask}
            />
            {shouldShowWorkspaceSetup ? (
              <WorkspaceSetupPanel
                teamSlugOrId={teamSlugOrId}
                projectFullName={selectedRepoFullName}
              />
            ) : null}

            {/* {shouldShowCloudRepoOnboarding && createEnvironmentSearch ? (
              <div className="mt-4 mb-4 flex items-start gap-2 rounded-xl border border-green-200/60 dark:border-green-500/40 bg-green-50/80 dark:bg-green-500/10 px-3 py-2 text-sm text-green-900 dark:text-green-100">
                <Info className="mt-0.5 h-4 w-4 flex-shrink-0 text-green-500 dark:text-green-300" />
                <div className="flex flex-col gap-1">
                  <p className="font-medium text-green-900 dark:text-green-100">
                    Set up an environment for {selectedRepoFullName}
                  </p>
                  <p className="text-xs text-green-900/80 dark:text-green-200/80">
                    Environments let you preconfigure development and maintenance scripts, pre-install packages, and environment variables so cloud workspaces are ready to go the moment they start.
                  </p>
                  <div className="flex gap-2 justify-end">
                    <button
                      type="button"
                      onClick={() => setHasDismissedCloudRepoOnboarding(true)}
                      className="inline-flex items-center rounded-md border border-green-200/60 bg-white/80 px-2 py-1 text-xs font-medium text-green-900/70 hover:bg-white dark:border-green-500/30 dark:bg-green-500/5 dark:text-green-100/80 dark:hover:bg-green-500/15"
                    >
                      Dismiss
                    </button>
                    <Link
                      to="/$teamSlugOrId/environments/new"
                      params={{ teamSlugOrId }}
                      search={createEnvironmentSearch}
                      onClick={handleStartEnvironmentSetup}
                      className="inline-flex items-center rounded-md border border-green-500/60 bg-green-500/10 px-2 py-1 text-xs font-medium text-green-900 dark:text-green-100 hover:bg-green-500/20"
                    >
                      Create environment
                    </Link>
                  </div>
                </div>
              </div>
            ) : null} */}
          </div>

          {/* Task List */}
          <div className="w-full">
            <TaskList teamSlugOrId={teamSlugOrId} />
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}

type DashboardMainCardProps = {
  editorApiRef: React.RefObject<EditorApi | null>;
  onTaskDescriptionChange: (value: string) => void;
  onSubmit: () => void;
  lexicalRepoUrl?: string;
  lexicalEnvironmentId?: Id<"environments">;
  lexicalBranch?: string;
  projectOptions: SelectOption[];
  selectedProject: string[];
  onProjectChange: (newProjects: string[]) => void;
  onProjectSearchPaste?: (value: string) => boolean | Promise<boolean>;
  branchOptions: string[];
  selectedBranch: string[];
  onBranchChange: (newBranches: string[]) => void;
  onBranchSearchChange: (search: string) => void;
  isBranchSearchLoading: boolean;
  selectedAgents: string[];
  onAgentChange: (newAgents: string[]) => void;
  isCloudMode: boolean;
  onCloudModeToggle: () => void;
  isLoadingProjects: boolean;
  isLoadingBranches: boolean;
  teamSlugOrId: string;
  cloudToggleDisabled: boolean;
  branchDisabled: boolean;
  providerStatus: ProviderStatusResponse | null;
  canSubmit: boolean;
  onStartTask: () => void;
  isStartingTask: boolean;
};

function DashboardMainCard({
  editorApiRef,
  onTaskDescriptionChange,
  onSubmit,
  lexicalRepoUrl,
  lexicalEnvironmentId,
  lexicalBranch,
  projectOptions,
  selectedProject,
  onProjectChange,
  onProjectSearchPaste,
  branchOptions,
  selectedBranch,
  onBranchChange,
  onBranchSearchChange,
  isBranchSearchLoading,
  selectedAgents,
  onAgentChange,
  isCloudMode,
  onCloudModeToggle,
  isLoadingProjects,
  isLoadingBranches,
  teamSlugOrId,
  cloudToggleDisabled,
  branchDisabled,
  providerStatus,
  canSubmit,
  onStartTask,
  isStartingTask,
}: DashboardMainCardProps) {
  return (
    <div className="relative bg-white dark:bg-neutral-700/50 border border-neutral-500/15 dark:border-neutral-500/15 rounded-2xl transition-all">
      <DashboardInput
        ref={editorApiRef}
        onTaskDescriptionChange={onTaskDescriptionChange}
        onSubmit={onSubmit}
        repoUrl={lexicalRepoUrl}
        environmentId={lexicalEnvironmentId}
        branch={lexicalBranch}
        persistenceKey="dashboard-task-description"
        maxHeight="300px"
      />

      <DashboardInputFooter>
        <DashboardInputControls
          projectOptions={projectOptions}
          selectedProject={selectedProject}
          onProjectChange={onProjectChange}
          onProjectSearchPaste={onProjectSearchPaste}
          branchOptions={branchOptions}
          selectedBranch={selectedBranch}
          onBranchChange={onBranchChange}
          onBranchSearchChange={onBranchSearchChange}
          isBranchSearchLoading={isBranchSearchLoading}
          selectedAgents={selectedAgents}
          onAgentChange={onAgentChange}
          isCloudMode={isCloudMode}
          onCloudModeToggle={onCloudModeToggle}
          isLoadingProjects={isLoadingProjects}
          isLoadingBranches={isLoadingBranches}
          teamSlugOrId={teamSlugOrId}
          cloudToggleDisabled={cloudToggleDisabled}
          branchDisabled={branchDisabled}
          providerStatus={providerStatus}
        />
        <DashboardStartTaskButton
          canSubmit={canSubmit}
          onStartTask={onStartTask}
          isStarting={isStartingTask}
          disabledReason={isStartingTask ? "Starting task..." : undefined}
        />
      </DashboardInputFooter>
    </div>
  );
}
