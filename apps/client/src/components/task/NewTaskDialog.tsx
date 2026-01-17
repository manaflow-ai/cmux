import {
  DashboardInput,
  type EditorApi,
} from "@/components/dashboard/DashboardInput";
import { DashboardInputControls } from "@/components/dashboard/DashboardInputControls";
import { DashboardInputFooter } from "@/components/dashboard/DashboardInputFooter";
import { DashboardStartTaskButton } from "@/components/dashboard/DashboardStartTaskButton";
import { useTheme } from "@/components/theme/use-theme";
import { useExpandTasks } from "@/contexts/expand-tasks/ExpandTasksContext";
import { useSocket } from "@/contexts/socket/use-socket";
import { attachTaskLifecycleListeners } from "@/lib/socket/taskLifecycleListeners";
import { branchesQueryOptions } from "@/queries/branches";
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
import * as Dialog from "@radix-ui/react-dialog";
import { useQuery } from "@tanstack/react-query";
import { useMutation } from "convex/react";
import { X } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import { z } from "zod";

interface NewTaskDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  teamSlugOrId: string;
}

// Default agents (not persisted to localStorage)
const DEFAULT_AGENTS = [
  "claude/sonnet-4.5",
  "claude/opus-4.1",
  "codex/gpt-5-codex-high",
];
const KNOWN_AGENT_NAMES = new Set(AGENT_CONFIGS.map((agent) => agent.name));
const DEFAULT_AGENT_SELECTION = DEFAULT_AGENTS.filter((agent) =>
  KNOWN_AGENT_NAMES.has(agent),
);

const AGENT_SELECTION_SCHEMA = z.array(z.string());

const filterKnownAgents = (agents: string[]): string[] =>
  agents.filter((agent) => KNOWN_AGENT_NAMES.has(agent));

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

export function NewTaskDialog({
  open,
  onOpenChange,
  teamSlugOrId,
}: NewTaskDialogProps) {
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
      localStorage.getItem("selectedAgents"),
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
    [setSelectedAgentsState],
  );

  const [taskDescription, setTaskDescription] = useState<string>("");
  const [isCloudMode, setIsCloudMode] = useState<boolean>(() => {
    const stored = localStorage.getItem("isCloudMode");
    return stored ? JSON.parse(stored) : true;
  });

  const [providerStatus, setProviderStatus] =
    useState<ProviderStatusResponse | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  // Ref to access editor API
  const editorApiRef = useRef<EditorApi | null>(null);

  const createTask = useMutation(api.tasks.create);
  const generateUploadUrl = useMutation(api.storage.generateUploadUrl);
  const reposByOrgQuery = useQuery(
    convexQuery(api.github.getReposByOrg, { teamSlugOrId }),
  );
  const reposByOrg = useMemo(
    () => reposByOrgQuery.data || {},
    [reposByOrgQuery.data],
  );

  const persistAgentSelection = useCallback((agents: string[]) => {
    try {
      const isDefaultSelection =
        DEFAULT_AGENT_SELECTION.length > 0 &&
        agents.length === DEFAULT_AGENT_SELECTION.length &&
        agents.every(
          (agent, index) => agent === DEFAULT_AGENT_SELECTION[index],
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

  // Callback for task description changes
  const handleTaskDescriptionChange = useCallback((value: string) => {
    setTaskDescription(value);
  }, []);

  // Fetch branches for selected repo from Convex
  const isEnvSelected = useMemo(
    () => (selectedProject[0] || "").startsWith("env:"),
    [selectedProject],
  );

  const branchesQuery = useQuery({
    ...branchesQueryOptions({
      teamSlugOrId,
      repoFullName: selectedProject[0] || "",
    }),
    enabled: !!selectedProject[0] && !isEnvSelected,
  });
  const branchSummary = useMemo(() => {
    const data = branchesQuery.data;
    if (!data?.branches) {
      return {
        names: [] as string[],
        defaultName: undefined as string | undefined,
      };
    }
    const names = data.branches.map((branch) => branch.name);
    const fromResponse = data.defaultBranch?.trim();
    const flaggedDefault = data.branches.find(
      (branch) => branch.isDefault,
    )?.name;
    const normalizedFromResponse =
      fromResponse && names.includes(fromResponse) ? fromResponse : undefined;
    const normalizedFlagged =
      flaggedDefault && names.includes(flaggedDefault)
        ? flaggedDefault
        : undefined;

    return {
      names,
      defaultName: normalizedFromResponse ?? normalizedFlagged,
    };
  }, [branchesQuery.data]);

  const branchNames = branchSummary.names;
  const remoteDefaultBranch = branchSummary.defaultName;

  // Callback for project selection changes
  const handleProjectChange = useCallback(
    (newProjects: string[]) => {
      setSelectedProject(newProjects);
      localStorage.setItem(
        `selectedProject-${teamSlugOrId}`,
        JSON.stringify(newProjects),
      );
      setSelectedBranch([]);
    },
    [teamSlugOrId],
  );

  // Callback for branch selection changes
  const handleBranchChange = useCallback((newBranches: string[]) => {
    setSelectedBranch(newBranches);
  }, []);

  // Callback for agent selection changes
  const handleAgentChange = useCallback(
    (newAgents: string[]) => {
      setSelectedAgents(newAgents);
      persistAgentSelection(newAgents);
    },
    [setSelectedAgents, persistAgentSelection],
  );

  // Callback for cloud mode toggle
  const handleCloudModeToggle = useCallback(() => {
    setIsCloudMode((prev) => {
      const next = !prev;
      localStorage.setItem("isCloudMode", JSON.stringify(next));
      return next;
    });
  }, []);

  // Compute effective selected branch (respects available branches and sensible defaults)
  const effectiveSelectedBranch = useMemo(() => {
    if (selectedBranch.length > 0 && branchNames.includes(selectedBranch[0])) {
      return selectedBranch;
    }
    if (remoteDefaultBranch) {
      return [remoteDefaultBranch];
    }
    if (branchNames.length > 0) {
      return [branchNames[0]];
    }
    return [];
  }, [selectedBranch, branchNames, remoteDefaultBranch]);

  const checkProviderStatus = useCallback(() => {
    if (!socket) return;

    socket.emit("check-provider-status", (response) => {
      if (!response) return;
      setProviderStatus(response);
    });
  }, [socket]);

  // Handler for task submission
  const handleSubmit = useCallback(
    async (e?: React.FormEvent) => {
      e?.preventDefault();
      if (!selectedProject[0] || !taskDescription.trim()) {
        toast.error("Please select a project and enter a task description");
        return;
      }
      if (!socket) {
        toast.error("Socket not connected");
        return;
      }

      setIsSubmitting(true);

      // Use the effective selected branch (respects available branches and sensible defaults)
      const branch = effectiveSelectedBranch[0];
      const projectFullName = selectedProject[0];
      const envSelected = projectFullName.startsWith("env:");
      const environmentId = envSelected
        ? (projectFullName.replace(/^env:/, "") as Id<"environments">)
        : undefined;

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
            },
          ),
        );

        // Create task in Convex with storage IDs
        const taskId = await createTask({
          teamSlugOrId,
          text: content?.text || taskDescription,
          projectFullName: envSelected ? undefined : projectFullName,
          baseBranch: envSelected ? undefined : branch,
          images: uploadedImages.length > 0 ? uploadedImages : undefined,
          environmentId,
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
            taskDescription: content?.text || taskDescription,
            projectFullName,
            taskId,
            selectedAgents:
              selectedAgents.length > 0 ? selectedAgents : undefined,
            isCloudMode: envSelected ? true : isCloudMode,
            ...(environmentId ? { environmentId } : {}),
            images: images.length > 0 ? images : undefined,
            theme,
          },
          handleStartTaskAck,
        );

        console.log("Task created:", taskId);
        toast.success("Task created successfully!");

        // Clear form and close dialog
        setTaskDescription("");
        handleTaskDescriptionChange("");
        if (editorApiRef.current?.clear) {
          editorApiRef.current.clear();
        }
        onOpenChange(false);
      } catch (error) {
        console.error("Error starting task:", error);
        toast.error("Failed to create task");
      } finally {
        setIsSubmitting(false);
      }
    },
    [
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
      onOpenChange,
    ],
  );

  // Fetch environments
  const environmentsQuery = useQuery(
    convexQuery(api.environments.list, { teamSlugOrId }),
  );

  const projectOptions = useMemo(() => {
    // Repo options as objects with GitHub icon
    const repoDocs = Object.values(reposByOrg).flatMap((repos) => repos);
    const uniqueRepos = repoDocs.reduce(
      (acc, repo) => {
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
      },
      new Map<string, Doc<"repos">>(),
    );
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
      icon: "github" as const,
    }));

    // Environment options with server icon
    const environments = environmentsQuery.data || [];
    const envOptions = environments.map((env) => ({
      label: env.name,
      value: `env:${env._id}`,
      icon: "server" as const,
    }));

    return [...envOptions, ...repoOptions];
  }, [reposByOrg, environmentsQuery.data]);

  const branchOptions = useMemo(() => {
    return branchNames;
  }, [branchNames]);

  // Reset form when dialog closes
  useEffect(() => {
    if (!open) {
      setIsSubmitting(false);
    }
  }, [open]);

  // Check provider status
  useEffect(() => {
    if (!open) return;
    checkProviderStatus();
  }, [open, checkProviderStatus]);

  const lexicalRepoUrl = useMemo(() => {
    if (selectedProject[0] && !isEnvSelected) {
      return `https://github.com/${selectedProject[0]}.git`;
    }
    return undefined;
  }, [selectedProject, isEnvSelected]);

  const lexicalEnvironmentId = useMemo(() => {
    if (isEnvSelected && selectedProject[0]) {
      return selectedProject[0].replace(/^env:/, "") as Id<"environments">;
    }
    return undefined;
  }, [isEnvSelected, selectedProject]);

  const lexicalBranch = effectiveSelectedBranch[0];

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-[var(--z-modal)] bg-black/30 backdrop-blur-sm data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-[var(--z-modal)] w-full max-w-[800px] -translate-x-1/2 -translate-y-1/2 rounded-lg border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 shadow-lg data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[state=closed]:slide-out-to-left-1/2 data-[state=closed]:slide-out-to-top-[48%] data-[state=open]:slide-in-from-left-1/2 data-[state=open]:slide-in-from-top-[48%]">
          <div className="flex flex-col h-full max-h-[80vh]">
            {/* Header */}
            <div className="flex items-center justify-between px-6 py-4 border-b border-neutral-200 dark:border-neutral-800">
              <div>
                <Dialog.Title className="text-lg font-semibold text-neutral-900 dark:text-neutral-100">
                  New Task
                </Dialog.Title>
                <Dialog.Description className="text-sm text-neutral-600 dark:text-neutral-400 mt-1">
                  Create a new task for your agents to work on
                </Dialog.Description>
              </div>
              <Dialog.Close
                className="rounded-md p-1.5 hover:bg-neutral-100 dark:hover:bg-neutral-800 text-neutral-500 dark:text-neutral-400"
                aria-label="Close"
              >
                <X className="h-5 w-5" />
              </Dialog.Close>
            </div>

            {/* Content */}
            <form
              onSubmit={handleSubmit}
              className="flex flex-col flex-1 overflow-hidden"
            >
              <div className="flex flex-col flex-1 overflow-auto px-6 py-4">
                <div className="relative bg-white dark:bg-neutral-700/50 border border-neutral-500/15 dark:border-neutral-500/15 rounded-2xl transition-all">
                  {/* Task Description Editor */}
                  <DashboardInput
                    ref={editorApiRef}
                    onTaskDescriptionChange={handleTaskDescriptionChange}
                    onSubmit={handleSubmit}
                    repoUrl={lexicalRepoUrl}
                    branch={lexicalBranch}
                    environmentId={lexicalEnvironmentId}
                    persistenceKey="newTaskDialog"
                    maxHeight="300px"
                  />

                  {/* Footer with Controls */}
                  <DashboardInputFooter>
                    <DashboardInputControls
                      projectOptions={projectOptions}
                      selectedProject={selectedProject}
                      onProjectChange={handleProjectChange}
                      branchOptions={branchOptions}
                      selectedBranch={selectedBranch}
                      onBranchChange={handleBranchChange}
                      selectedAgents={selectedAgents}
                      onAgentChange={handleAgentChange}
                      isCloudMode={isCloudMode}
                      onCloudModeToggle={handleCloudModeToggle}
                      isLoadingProjects={reposByOrgQuery.isLoading}
                      isLoadingBranches={branchesQuery.isLoading}
                      teamSlugOrId={teamSlugOrId}
                      cloudToggleDisabled={isEnvSelected}
                      branchDisabled={isEnvSelected}
                      providerStatus={providerStatus}
                    />
                    <DashboardStartTaskButton
                      canSubmit={
                        !!selectedProject[0] && !!taskDescription.trim() && !isSubmitting
                      }
                      onStartTask={handleSubmit}
                    />
                  </DashboardInputFooter>
                </div>
              </div>
            </form>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
