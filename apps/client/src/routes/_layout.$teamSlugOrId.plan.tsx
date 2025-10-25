import { FloatingPane } from "@/components/floating-pane";
import { TaskMessage } from "@/components/task-message";
import { DashboardInputControls } from "@/components/dashboard/DashboardInputControls";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import {
  filterKnownAgents,
  loadPersistedAgentSelection,
  persistAgentSelection,
} from "@/lib/taskAgentSelection";
import {
  writePendingPlanTask,
  type PendingPlanTaskPayload,
} from "@/lib/planMode";
import { TitleBar } from "@/components/TitleBar";
import { branchesQueryOptions } from "@/queries/branches";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import { convexQuery } from "@convex-dev/react-query";
import { postApiPlanChatMutation } from "@cmux/www-openapi-client/react-query";
import type { PlanChatBody } from "@cmux/www-openapi-client";
import { GitHubIcon } from "@/components/icons/github";
import { Server as ServerIcon, ClipboardCopy, Send, Sparkles } from "lucide-react";
import {
  useCallback,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type FormEvent,
  type ReactNode,
} from "react";
import { useQuery, useMutation as useRQMutation } from "@tanstack/react-query";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { toast } from "sonner";

const MAX_CONTEXT_SNIPPET_LENGTH = 6000;
const MAX_FOLLOW_UPS = 4;

type PlanTask = {
  id: string;
  title: string;
  prompt: string;
  rationale?: string;
  priority?: "high" | "medium" | "low";
};

type PlanMessage = {
  id: string;
  role: "user" | "assistant";
  content: string;
  createdAt: number;
  tasks?: PlanTask[];
  followUpQuestions?: string[];
};

type ContextSnippet = {
  id: string;
  path: string;
  content: string;
  source: "manual" | "github";
};

const introAssistantMessage: PlanMessage = {
  id: "assistant-intro",
  role: "assistant",
  createdAt: Date.now(),
  content:
    "I'm ready to help you plan. Select a repository, share any files that matter, then describe what you want to accomplish.",
};

export const Route = createFileRoute("/_layout/$teamSlugOrId/plan")({
  component: PlanModePage,
});

function useLocalStorageState(key: string, defaultValue: string[]): [string[], (value: string[]) => void] {
  const [state, setState] = useState<string[]>(() => {
    if (typeof window === "undefined") {
      return defaultValue;
    }
    try {
      const stored = window.localStorage.getItem(key);
      if (!stored) {
        return defaultValue;
      }
      const parsed = JSON.parse(stored) as unknown;
      if (Array.isArray(parsed)) {
        return parsed.filter((item): item is string => typeof item === "string");
      }
      return defaultValue;
    } catch (error) {
      console.warn(`Failed to parse localStorage value for ${key}`, error);
      return defaultValue;
    }
  });

  const updateState = useCallback((value: string[]) => {
    setState(value);
    if (typeof window !== "undefined") {
      try {
        window.localStorage.setItem(key, JSON.stringify(value));
      } catch (error) {
        console.warn(`Failed to set localStorage value for ${key}`, error);
      }
    }
  }, [key]);

  return [state, updateState];
}

function sanitizeSnippetContent(content: string): string {
  if (!content) {
    return content;
  }
  return content.length > MAX_CONTEXT_SNIPPET_LENGTH
    ? `${content.slice(0, MAX_CONTEXT_SNIPPET_LENGTH)}\n…`
    : content;
}

function toPlanChatBody({
  teamSlugOrId,
  repoFullName,
  branch,
  messages,
  contextSnippets,
}: {
  teamSlugOrId: string;
  repoFullName?: string | null;
  branch?: string | null;
  messages: PlanMessage[];
  contextSnippets: ContextSnippet[];
}): PlanChatBody {
  return {
    teamSlugOrId,
    repoFullName: repoFullName ?? undefined,
    branch: branch ?? undefined,
    messages: messages.map((message) => ({
      role: message.role,
      content: message.content,
    })),
    contextSnippets:
      contextSnippets.length > 0
        ? contextSnippets.map((snippet) => ({
          path: snippet.path,
          content: sanitizeSnippetContent(snippet.content),
        }))
        : undefined,
  };
}

function PlanModePage() {
  const { teamSlugOrId } = Route.useParams();
  const navigate = useNavigate();

  const [messages, setMessages] = useState<PlanMessage[]>([introAssistantMessage]);
  const messagesRef = useRef(messages);
  messagesRef.current = messages;

  const [draft, setDraft] = useState("");
  const [contextSnippets, setContextSnippets] = useState<ContextSnippet[]>([]);
  const [manualSnippetTitle, setManualSnippetTitle] = useState("");
  const [manualSnippetContent, setManualSnippetContent] = useState("");
  const [filePathInput, setFilePathInput] = useState("");
  const [isFetchingFile, setIsFetchingFile] = useState(false);

  const [selectedProject, setSelectedProject] = useLocalStorageState(
    "selectedProject",
    [],
  );
  const [selectedBranch, setSelectedBranch] = useState<string[]>([]);
  const [selectedAgents, setSelectedAgentsState] = useState<string[]>(
    () => loadPersistedAgentSelection(),
  );
  const selectedAgentsRef = useRef(selectedAgents);
  selectedAgentsRef.current = selectedAgents;

  const [isCloudMode, setIsCloudMode] = useState<boolean>(() => {
    if (typeof window === "undefined") {
      return true;
    }
    const stored = window.localStorage.getItem("isCloudMode");
    return stored ? JSON.parse(stored) : true;
  });

  const setSelectedAgents = useCallback((agents: string[]) => {
    const filtered = filterKnownAgents(agents);
    setSelectedAgentsState(filtered);
    persistAgentSelection(filtered);
  }, []);

  const repoFullName = selectedProject[0] && !selectedProject[0].startsWith("env:")
    ? selectedProject[0]
    : undefined;
  const isEnvironmentSelected = useMemo(
    () => Boolean(selectedProject[0]?.startsWith("env:")),
    [selectedProject],
  );

  const branchesQuery = useQuery({
    ...branchesQueryOptions({
      teamSlugOrId,
      repoFullName: repoFullName ?? "",
    }),
    enabled: Boolean(repoFullName),
  });

  const branchSummary = useMemo(() => {
    const data = branchesQuery.data;
    if (!data?.branches) {
      return { names: [] as string[], defaultName: undefined as string | undefined };
    }
    const names = data.branches.map((branch) => branch.name);
    const fromResponse = data.defaultBranch?.trim();
    const flaggedDefault = data.branches.find((branch) => branch.isDefault)?.name;
    const normalizedFromResponse =
      fromResponse && names.includes(fromResponse) ? fromResponse : undefined;
    const normalizedFlagged =
      flaggedDefault && names.includes(flaggedDefault) ? flaggedDefault : undefined;
    return {
      names,
      defaultName: normalizedFromResponse ?? normalizedFlagged,
    };
  }, [branchesQuery.data]);

  const branchNames = branchSummary.names;
  const remoteDefaultBranch = branchSummary.defaultName;

  const effectiveSelectedBranch = useMemo(() => {
    if (isEnvironmentSelected) {
      return [];
    }
    if (selectedBranch.length > 0) {
      return selectedBranch;
    }
    if (branchNames.length === 0) {
      return [];
    }
    const fallback = branchNames.includes("main")
      ? "main"
      : branchNames.includes("master")
        ? "master"
        : branchNames[0];
    const preferred =
      remoteDefaultBranch && branchNames.includes(remoteDefaultBranch)
        ? remoteDefaultBranch
        : fallback;
    return [preferred];
  }, [branchNames, remoteDefaultBranch, selectedBranch, isEnvironmentSelected]);

  const reposByOrgQuery = useQuery({
    ...convexQuery(api.github.getReposByOrg, { teamSlugOrId }),
    refetchOnMount: "always",
    refetchOnWindowFocus: false,
  });
  const environmentsQuery = useQuery(
    convexQuery(api.environments.list, { teamSlugOrId }),
  );

  const projectOptions = useMemo(() => {
    const repoDocs = Object.values(reposByOrgQuery.data || {}).flatMap((repos) => repos);
    const uniqueRepos = repoDocs.reduce((acc, repo) => {
      const existing = acc.get(repo.fullName);
      if (!existing) {
        acc.set(repo.fullName, repo);
        return acc;
      }
      const existingActivity = existing.lastPushedAt ?? Number.NEGATIVE_INFINITY;
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

    const envOptions = (environmentsQuery.data || []).map((env) => ({
      label: env.name,
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

    const options = [] as Array<{
      label: string;
      value: string;
      heading?: boolean;
      icon?: ReactNode;
      iconKey?: string;
    }>;

    if (envOptions.length > 0) {
      options.push({ label: "Environments", value: "__heading-env", heading: true });
      options.push(...envOptions);
    }
    if (repoOptions.length > 0) {
      options.push({ label: "Repositories", value: "__heading-repo", heading: true });
      options.push(...repoOptions);
    }
    return options;
  }, [reposByOrgQuery.data, environmentsQuery.data]);

  const planMutation = useRQMutation(postApiPlanChatMutation());

  const latestAssistantMessage = useMemo(() => {
    for (let i = messages.length - 1; i >= 0; i -= 1) {
      if (messages[i].role === "assistant") {
        return messages[i];
      }
    }
    return null;
  }, [messages]);

  const followUpSuggestions = latestAssistantMessage?.followUpQuestions?.slice(
    0,
    MAX_FOLLOW_UPS,
  );

  const handleSend = useCallback(async () => {
    const trimmed = draft.trim();
    if (!trimmed) {
      return;
    }

    const newUserMessage: PlanMessage = {
      id: crypto.randomUUID(),
      role: "user",
      content: trimmed,
      createdAt: Date.now(),
    };

    setMessages((prev) => [...prev, newUserMessage]);
    setDraft("");

    const conversation = [...messagesRef.current, newUserMessage];

    try {
      const response = await planMutation.mutateAsync({
        body: toPlanChatBody({
          teamSlugOrId,
          repoFullName,
          branch: effectiveSelectedBranch[0],
          messages: conversation,
          contextSnippets,
        }),
      });

      const assistantMessage: PlanMessage = {
        id: crypto.randomUUID(),
        role: "assistant",
        content: response.reply,
        createdAt: Date.now(),
        tasks: (response.tasks ?? []).map((task, index) => ({
          id: `${Date.now()}-${index}`,
          title: task.title,
          prompt: task.prompt,
          rationale: task.rationale,
          priority: task.priority,
        })),
        followUpQuestions: response.followUpQuestions ?? [],
      };

      setMessages((prev) => [...prev, assistantMessage]);
    } catch (error) {
      console.error("Plan mode request failed", error);
      toast.error("Plan mode request failed. Check your API key configuration and try again.");
    }
  }, [draft, contextSnippets, effectiveSelectedBranch, planMutation, repoFullName, teamSlugOrId]);

  const handleDraftKeyDown = useCallback((event: KeyboardEvent<HTMLTextAreaElement>) => {
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault();
      void handleSend();
    }
  }, [handleSend]);

  const handleAddManualSnippet = useCallback(() => {
    const content = manualSnippetContent.trim();
    if (!content) {
      toast.error("Add snippet text before saving.");
      return;
    }
    const title = manualSnippetTitle.trim() || `Note ${contextSnippets.length + 1}`;
    const snippet: ContextSnippet = {
      id: crypto.randomUUID(),
      path: title,
      content,
      source: "manual",
    };
    setContextSnippets((prev) => [...prev, snippet]);
    setManualSnippetTitle("");
    setManualSnippetContent("");
  }, [contextSnippets.length, manualSnippetContent, manualSnippetTitle]);

  const handleFetchFileSnippet = useCallback(async () => {
    const repo = repoFullName;
    if (!repo) {
      toast.error("Select a repository before fetching files.");
      return;
    }
    const path = filePathInput.trim().replace(/^\/+/, "");
    if (!path) {
      toast.error("Enter a file path to fetch.");
      return;
    }
    const branch = effectiveSelectedBranch[0] ?? "main";
    const url = `https://raw.githubusercontent.com/${repo}/${encodeURIComponent(branch)}/${path}`;

    setIsFetchingFile(true);
    try {
      const res = await fetch(url);
      if (!res.ok) {
        throw new Error(`Failed to download ${path}`);
      }
      const text = await res.text();
      const snippet: ContextSnippet = {
        id: crypto.randomUUID(),
        path,
        content: text,
        source: "github",
      };
      setContextSnippets((prev) => [...prev, snippet]);
      setFilePathInput("");
      toast.success(`Added ${path} from ${branch}.`);
    } catch (error) {
      console.error("Failed to fetch file", error);
      toast.error("Could not fetch that file from GitHub.");
    } finally {
      setIsFetchingFile(false);
    }
  }, [effectiveSelectedBranch, filePathInput, repoFullName]);

  const handleRemoveSnippet = useCallback((id: string) => {
    setContextSnippets((prev) => prev.filter((snippet) => snippet.id !== id));
  }, []);

  const handleAgentChange = useCallback((agents: string[]) => {
    setSelectedAgents(agents);
  }, [setSelectedAgents]);

  const handleProjectChange = useCallback((projects: string[]) => {
    setSelectedProject(projects);
    if (projects[0] !== selectedProject[0]) {
      setSelectedBranch([]);
    }
    if (projects[0]?.startsWith("env:")) {
      setIsCloudMode(true);
      if (typeof window !== "undefined") {
        window.localStorage.setItem("isCloudMode", JSON.stringify(true));
      }
    }
  }, [selectedProject, setSelectedProject]);

  const handleBranchChange = useCallback((branches: string[]) => {
    setSelectedBranch(branches);
  }, []);

  const handleCloudToggle = useCallback(() => {
    setIsCloudMode((prev) => {
      const next = !prev;
      if (typeof window !== "undefined") {
        window.localStorage.setItem("isCloudMode", JSON.stringify(next));
      }
      return next;
    });
  }, []);

  const copyPrompt = useCallback(async (prompt: string) => {
    try {
      await navigator.clipboard.writeText(prompt);
      toast.success("Copied task prompt to clipboard.");
    } catch (error) {
      console.error("Failed to copy prompt", error);
      toast.error("Could not copy prompt. Copy manually instead.");
    }
  }, []);

  const launchTaskFromPlan = useCallback(async (
    task: PlanTask,
    options: { autoStart: boolean },
  ) => {
    const repo = selectedProject[0];
    if (!repo) {
      toast.error("Select a repository before launching a task.");
      return;
    }
    if (selectedAgentsRef.current.length === 0) {
      toast.error("Choose at least one agent before launching a task.");
      return;
    }

    const payload: PendingPlanTaskPayload = {
      prompt: task.prompt,
      repoFullName: repo.startsWith("env:") ? undefined : repo,
      branch: repo.startsWith("env:") ? undefined : (effectiveSelectedBranch[0] ?? null),
      isCloudMode: repo.startsWith("env:") ? true : isCloudMode,
      selectedAgents: selectedAgentsRef.current,
      shouldAutoStart: options.autoStart,
      title: task.title,
    };

    writePendingPlanTask(payload);

    await navigate({
      to: "/$teamSlugOrId/dashboard",
      params: { teamSlugOrId },
    });
  }, [effectiveSelectedBranch, isCloudMode, navigate, selectedProject, teamSlugOrId]);

  const handleFollowUpClick = useCallback((question: string) => {
    setDraft((prev) => (prev ? `${prev}\n\n${question}` : question));
  }, []);

  const conversationContent = (
    <div className="flex flex-col gap-4">
      {messages.map((message) => (
        <div key={message.id} className="space-y-2">
          <TaskMessage
            authorName={message.role === "assistant" ? "Plan Mode" : "You"}
            content={message.content}
            timestamp={message.createdAt}
            avatar={
              message.role === "assistant" ? (
                <Sparkles className="w-4 h-4 text-neutral-400" />
              ) : undefined
            }
          />
          {message.tasks && message.tasks.length > 0 ? (
            <div className="space-y-3">
              {message.tasks.map((task) => (
                <div
                  key={task.id}
                  className="border border-neutral-200 dark:border-neutral-800 rounded-lg p-3 bg-white/70 dark:bg-neutral-900/60"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <h4 className="text-sm font-semibold text-neutral-900 dark:text-neutral-100">
                        {task.title}
                      </h4>
                      {task.priority ? (
                        <span className="mt-1 inline-flex items-center rounded-full bg-neutral-200 dark:bg-neutral-800 px-2 py-0.5 text-[11px] uppercase tracking-wide text-neutral-600 dark:text-neutral-300">
                          {task.priority}
                        </span>
                      ) : null}
                    </div>
                    <div className="flex items-center gap-2">
                      <Button
                        size="sm"
                        variant="outline"
                        className="h-7 text-xs"
                        onClick={() => {
                          void copyPrompt(task.prompt);
                        }}
                      >
                        <ClipboardCopy className="w-3.5 h-3.5 mr-1" /> Copy
                      </Button>
                      <Button
                        size="sm"
                        variant="secondary"
                        className="h-7 text-xs"
                        onClick={() => {
                          void launchTaskFromPlan(task, { autoStart: false });
                        }}
                      >
                        Queue
                      </Button>
                      <Button
                        size="sm"
                        className="h-7 text-xs"
                        onClick={() => {
                          void launchTaskFromPlan(task, { autoStart: true });
                        }}
                      >
                        Start
                      </Button>
                    </div>
                  </div>
                  <div className="mt-2 space-y-2">
                    {task.rationale ? (
                      <p className="text-sm text-neutral-600 dark:text-neutral-300 whitespace-pre-wrap">
                        {task.rationale}
                      </p>
                    ) : null}
                    <div className="bg-neutral-100 dark:bg-neutral-800 rounded-md p-2 text-xs font-mono whitespace-pre-wrap text-neutral-700 dark:text-neutral-200">
                      {task.prompt}
                    </div>
                  </div>
                </div>
              ))}
            </div>
          ) : null}
        </div>
      ))}
    </div>
  );

  return (
    <FloatingPane
      header={
        <>
          <TitleBar title="Plan Mode" />
          <div className="border-b border-neutral-200/70 dark:border-neutral-800/50 px-4 py-3 text-sm text-neutral-600 dark:text-neutral-300">
            Chat with GPT-5 Pro to break work into launch-ready tasks before you start agents.
          </div>
        </>
      }
    >
      <div className="flex h-full flex-col gap-4 p-4 overflow-hidden">
        <DashboardInputControls
          projectOptions={projectOptions}
          selectedProject={selectedProject}
          onProjectChange={handleProjectChange}
          branchOptions={branchNames}
          selectedBranch={selectedBranch}
          onBranchChange={handleBranchChange}
          selectedAgents={selectedAgents}
          onAgentChange={handleAgentChange}
          isCloudMode={isCloudMode}
          onCloudModeToggle={handleCloudToggle}
          isLoadingProjects={Boolean(reposByOrgQuery.isLoading)}
          isLoadingBranches={branchesQuery.isLoading}
          teamSlugOrId={teamSlugOrId}
          cloudToggleDisabled={isEnvironmentSelected}
          branchDisabled={isEnvironmentSelected}
          providerStatus={null}
        />

        <div className="grid grid-cols-1 lg:grid-cols-[2fr_minmax(280px,1fr)] gap-4 min-h-[520px]">
          <div className="flex flex-col overflow-hidden border border-neutral-200 dark:border-neutral-800 rounded-xl bg-white/80 dark:bg-neutral-900/70">
            <div className="flex-1 overflow-y-auto p-4">
              {conversationContent}
            </div>
            <div className="border-t border-neutral-200 dark:border-neutral-800 p-4 space-y-3">
              {followUpSuggestions && followUpSuggestions.length > 0 ? (
                <div className="flex flex-wrap gap-2">
                  {followUpSuggestions.map((question) => (
                    <Button
                      key={question}
                      size="sm"
                      variant="outline"
                      className="h-7 text-xs"
                      onClick={() => handleFollowUpClick(question)}
                    >
                      {question}
                    </Button>
                  ))}
                </div>
              ) : null}
              <form
                className="space-y-3"
                onSubmit={(event: FormEvent<HTMLFormElement>) => {
                  event.preventDefault();
                  void handleSend();
                }}
              >
                <textarea
                  value={draft}
                  onChange={(event) => setDraft(event.target.value)}
                  onKeyDown={handleDraftKeyDown}
                  placeholder="What should we plan next?"
                  className="w-full min-h-[120px] rounded-lg border border-neutral-300 dark:border-neutral-700 bg-neutral-50 dark:bg-neutral-900/60 px-3 py-2 text-sm text-neutral-800 dark:text-neutral-100 shadow-inner focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-neutral-500 dark:focus-visible:outline-neutral-400"
                />
                <div className="flex justify-between items-center">
                  <span className="text-xs text-neutral-500 dark:text-neutral-400">
                    Press ⌘+Enter to send
                  </span>
                  <Button type="submit" disabled={planMutation.isPending}>
                    <Send className="w-4 h-4 mr-2" />
                    {planMutation.isPending ? "Thinking…" : "Send"}
                  </Button>
                </div>
              </form>
            </div>
          </div>

          <div className="flex flex-col gap-3 border border-neutral-200 dark:border-neutral-800 rounded-xl bg-white/80 dark:bg-neutral-900/70 p-4 overflow-y-auto">
            <div>
              <h3 className="text-sm font-semibold text-neutral-900 dark:text-neutral-100">
                Context snippets
              </h3>
              <p className="text-xs text-neutral-500 dark:text-neutral-400">
                Share important files or notes so GPT-5 can plan accurately.
              </p>
            </div>

            <div className="space-y-2">
              <label className="text-xs uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
                Fetch file from repository
              </label>
              <div className="flex gap-2">
                <input
                  type="text"
                  value={filePathInput}
                  onChange={(event) => setFilePathInput(event.target.value)}
                  placeholder="src/components/Button.tsx"
                  className="flex-1 h-8 rounded-md border border-neutral-300 dark:border-neutral-700 bg-transparent px-2 text-sm text-neutral-800 dark:text-neutral-100"
                />
                <Button
                  type="button"
                  size="sm"
                  className="h-8"
                  disabled={isFetchingFile}
                  onClick={() => {
                    void handleFetchFileSnippet();
                  }}
                >
                  {isFetchingFile ? "Fetching…" : "Add"}
                </Button>
              </div>
              <p className="text-[11px] text-neutral-500 dark:text-neutral-500">
                Uses the selected branch ({effectiveSelectedBranch[0] ?? "main"}). Public repositories only.
              </p>
            </div>

            <div className="space-y-2">
              <label className="text-xs uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
                Add manual note
              </label>
              <input
                type="text"
                value={manualSnippetTitle}
                onChange={(event) => setManualSnippetTitle(event.target.value)}
                placeholder="Snippet title"
                className="w-full h-8 rounded-md border border-neutral-300 dark:border-neutral-700 bg-transparent px-2 text-sm text-neutral-800 dark:text-neutral-100"
              />
              <textarea
                value={manualSnippetContent}
                onChange={(event) => setManualSnippetContent(event.target.value)}
                placeholder="Paste requirements, stack notes, or code fragments"
                className="w-full min-h-[80px] rounded-md border border-neutral-300 dark:border-neutral-700 bg-transparent px-2 py-2 text-sm text-neutral-800 dark:text-neutral-100"
              />
              <div className="flex justify-end">
                <Button
                  type="button"
                  size="sm"
                  variant="secondary"
                  className="h-8"
                  onClick={handleAddManualSnippet}
                >
                  Save note
                </Button>
              </div>
            </div>

            <div className="space-y-3">
              {contextSnippets.length === 0 ? (
                <p className="text-sm text-neutral-500 dark:text-neutral-400">
                  No context yet. Add files or notes so the assistant understands your codebase.
                </p>
              ) : (
                contextSnippets.map((snippet) => (
                  <div
                    key={snippet.id}
                    className="rounded-lg border border-neutral-200 dark:border-neutral-800 bg-neutral-50 dark:bg-neutral-900/40 p-3"
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <p className="text-sm font-semibold text-neutral-900 dark:text-neutral-100 break-all">
                          {snippet.path}
                        </p>
                        <p className="text-[11px] uppercase tracking-wide text-neutral-400 dark:text-neutral-500">
                          {snippet.source === "github" ? "GitHub" : "Manual note"}
                        </p>
                      </div>
                      <Button
                        type="button"
                        size="sm"
                        variant="ghost"
                        className="h-7 text-xs"
                        onClick={() => handleRemoveSnippet(snippet.id)}
                      >
                        Remove
                      </Button>
                    </div>
                    <pre className="mt-2 max-h-48 overflow-y-auto whitespace-pre-wrap text-xs text-neutral-700 dark:text-neutral-200">
                      {sanitizeSnippetContent(snippet.content)}
                    </pre>
                  </div>
                ))
              )}
            </div>
          </div>
        </div>
      </div>
    </FloatingPane>
  );
}
