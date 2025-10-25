import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import {
  useMutation,
  useQuery,
  useQueryClient,
  useSuspenseQuery,
} from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import clsx from "clsx";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Plus, X } from "lucide-react";
import z from "zod";
import {
  TaskRunTerminalSession,
  type TerminalConnectionState,
} from "@/components/task-run-terminal-session";
import { toMorphXtermBaseUrl } from "@/lib/toProxyWorkspaceUrl";
import {
  createTerminalTab,
  deleteTerminalTab,
  terminalTabsQueryKey,
  terminalTabsQueryOptions,
  type CreateTerminalTabRequest,
  type CreateTerminalTabResponse,
  type TerminalTabId,
} from "@/queries/terminals";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
});

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/terminals"
)({
  component: TaskRunTerminals,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => ({
      taskId: params.taskId,
      runId: params.runId,
    }),
  },
  loader: async (opts) => {
    const { params, context } = opts;
    const { teamSlugOrId, runId } = params;
    const { queryClient } = context;

    const taskRun = await queryClient.ensureQueryData(
      convexQuery(api.taskRuns.get, {
        teamSlugOrId,
        id: runId,
      })
    );

    const vscodeInfo = taskRun?.vscode;
    const rawMorphUrl = vscodeInfo?.url ?? vscodeInfo?.workspaceUrl ?? null;
    const isMorphProvider = vscodeInfo?.provider === "morph";

    if (!isMorphProvider || !rawMorphUrl) {
      return;
    }

    const baseUrl = toMorphXtermBaseUrl(rawMorphUrl);
    const tabsQueryKey = terminalTabsQueryKey(baseUrl, runId);

    const tabs = await queryClient.ensureQueryData(
      terminalTabsQueryOptions({
        baseUrl,
        contextKey: runId,
      })
    );

    if (tabs.length > 0) {
      return;
    }

    try {
      const created = await createTerminalTab({
        baseUrl,
        request: {
          cmd: "tmux",
          args: ["attach", "-t", "cmux"],
        },
      });

      queryClient.setQueryData<TerminalTabId[]>(tabsQueryKey, (current) => {
        if (!current || current.length === 0) {
          return [created.id];
        }
        if (current.includes(created.id)) {
          return current;
        }
        return [...current, created.id];
      });
    } catch (error) {
      console.error("Failed to auto-create tmux terminal", error);
    }
  },
});

const CONNECTION_STATE_COLORS: Record<TerminalConnectionState, string> = {
  open: "bg-emerald-500",
  connecting: "bg-amber-500",
  closed: "bg-neutral-400 dark:bg-neutral-600",
  error: "bg-red-500",
};

type DeleteTerminalMutationContext = {
  previousTabs: TerminalTabId[];
  previousActiveId: string | null;
  previousConnectionState: TerminalConnectionState;
};

function getTabRemovalOutcome(
  tabs: TerminalTabId[],
  removedId: TerminalTabId,
  currentActiveId: string | null
): { nextTabs: TerminalTabId[]; nextActiveId: string | null } {
  const nextTabs = tabs.filter((tabId) => tabId !== removedId);
  if (nextTabs.length === 0) {
    return { nextTabs, nextActiveId: null };
  }

  if (
    currentActiveId &&
    currentActiveId !== removedId &&
    nextTabs.includes(currentActiveId)
  ) {
    return { nextTabs, nextActiveId: currentActiveId };
  }

  const removedIndex = tabs.findIndex((tabId) => tabId === removedId);
  if (removedIndex !== -1) {
    const rightCandidate = tabs
      .slice(removedIndex + 1)
      .find((tabId) => tabId !== removedId && nextTabs.includes(tabId));
    if (rightCandidate) {
      return { nextTabs, nextActiveId: rightCandidate };
    }

    for (let index = removedIndex - 1; index >= 0; index -= 1) {
      const leftCandidate = tabs[index];
      if (leftCandidate && leftCandidate !== removedId) {
        if (nextTabs.includes(leftCandidate)) {
          return { nextTabs, nextActiveId: leftCandidate };
        }
      }
    }
  }

  return { nextTabs, nextActiveId: nextTabs[0] ?? null };
}

function TaskRunTerminals() {
  const { runId: taskRunId, teamSlugOrId } = Route.useParams();
  const taskRun = useSuspenseQuery(
    convexQuery(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    })
  );

  const vscodeInfo = taskRun?.data?.vscode;
  const rawMorphUrl = vscodeInfo?.url ?? vscodeInfo?.workspaceUrl ?? null;
  const isMorphProvider = vscodeInfo?.provider === "morph";

  const xtermBaseUrl = useMemo(() => {
    if (!rawMorphUrl) {
      return null;
    }
    return toMorphXtermBaseUrl(rawMorphUrl);
  }, [rawMorphUrl]);

  const hasTerminalBackend = Boolean(isMorphProvider && xtermBaseUrl);

  const tabsQuery = useQuery(
    terminalTabsQueryOptions({
      baseUrl: xtermBaseUrl,
      contextKey: taskRunId,
      enabled: hasTerminalBackend,
    })
  );

  const terminalIds = useMemo(() => tabsQuery.data ?? [], [tabsQuery.data]);

  const [activeTerminalId, setActiveTerminalId] = useState<string | null>(null);
  const [connectionStates, setConnectionStates] = useState<
    Record<string, TerminalConnectionState>
  >({});

  const queryClient = useQueryClient();

  const createTerminalMutation = useMutation<
    CreateTerminalTabResponse,
    unknown,
    CreateTerminalTabRequest | undefined,
    void
  >({
    mutationKey: ["terminal-tabs", taskRunId, xtermBaseUrl, "create"],
    mutationFn: async (request) =>
      createTerminalTab({
        baseUrl: xtermBaseUrl,
        request,
      }),
    onSuccess: (payload) => {
      const queryKey = terminalTabsQueryKey(xtermBaseUrl, taskRunId);
      queryClient.setQueryData<TerminalTabId[] | undefined>(
        queryKey,
        (current) => {
          if (!current) {
            return [payload.id];
          }
          if (current.includes(payload.id)) {
            return current;
          }
          return [...current, payload.id];
        }
      );
      setActiveTerminalId(payload.id);
      setConnectionStates((prev) => ({
        ...prev,
        [payload.id]: prev[payload.id] ?? "connecting",
      }));
    },
    onSettled: () => {
      queryClient.invalidateQueries({
        queryKey: terminalTabsQueryKey(xtermBaseUrl, taskRunId),
      });
    },
  });

  const deleteTerminalMutation = useMutation<
    void,
    unknown,
    TerminalTabId,
    DeleteTerminalMutationContext
  >({
    mutationKey: ["terminal-tabs", taskRunId, xtermBaseUrl, "delete"],
    mutationFn: async (tabId) =>
      deleteTerminalTab({
        baseUrl: xtermBaseUrl,
        tabId,
      }),
    onMutate: async (tabId) => {
      const queryKey = terminalTabsQueryKey(xtermBaseUrl, taskRunId);
      await queryClient.cancelQueries({ queryKey });
      const cachedTabs =
        queryClient.getQueryData<TerminalTabId[]>(queryKey) ?? terminalIds;
      const previousTabs = [...cachedTabs];
      const previousActiveId = activeTerminalId;
      const previousConnectionState = connectionStates[tabId] ?? "connecting";
      const { nextTabs, nextActiveId } = getTabRemovalOutcome(
        previousTabs,
        tabId,
        activeTerminalId
      );
      queryClient.setQueryData(queryKey, nextTabs);
      setActiveTerminalId(nextActiveId);
      setConnectionStates((prev) => {
        const { [tabId]: _removed, ...rest } = prev;
        return rest;
      });
      return {
        previousTabs,
        previousActiveId,
        previousConnectionState,
      };
    },
    onError: (_error, tabId, context) => {
      if (!context) {
        return;
      }
      const queryKey = terminalTabsQueryKey(xtermBaseUrl, taskRunId);
      queryClient.setQueryData(queryKey, context.previousTabs);
      setActiveTerminalId(() => {
        const desired = context.previousActiveId;
        if (desired && context.previousTabs.includes(desired)) {
          return desired;
        }
        return context.previousTabs[0] ?? null;
      });
      setConnectionStates((prev) => ({
        ...prev,
        [tabId]: context.previousConnectionState,
      }));
    },
    onSettled: () => {
      queryClient.invalidateQueries({
        queryKey: terminalTabsQueryKey(xtermBaseUrl, taskRunId),
      });
    },
  });

  const isCreatingTerminal = createTerminalMutation.isPending;
  const deletingTerminalId = deleteTerminalMutation.variables ?? null;
  const isDeletingTerminal = deleteTerminalMutation.isPending;
  const createTerminalErrorMessage =
    createTerminalMutation.error instanceof Error
      ? createTerminalMutation.error.message
      : createTerminalMutation.error
        ? "Unable to create terminal."
        : null;
  const deleteTerminalErrorMessage =
    deleteTerminalMutation.error instanceof Error
      ? deleteTerminalMutation.error.message
      : deleteTerminalMutation.error
        ? "Unable to close terminal."
        : null;

  useEffect(() => {
    if (!hasTerminalBackend || terminalIds.length === 0) {
      setActiveTerminalId(null);
    } else {
      setActiveTerminalId((current) =>
        current && terminalIds.includes(current) ? current : terminalIds[0]
      );
    }
  }, [hasTerminalBackend, terminalIds]);

  useEffect(() => {
    if (!hasTerminalBackend) {
      setConnectionStates({});
      return;
    }
    setConnectionStates((prev) => {
      const next: Record<string, TerminalConnectionState> = {};
      for (const id of terminalIds) {
        next[id] = prev[id] ?? "connecting";
      }
      const sameSize = Object.keys(prev).length === Object.keys(next).length;
      if (sameSize) {
        let unchanged = true;
        for (const id of terminalIds) {
          if (prev[id] !== next[id]) {
            unchanged = false;
            break;
          }
        }
        if (unchanged) {
          return prev;
        }
      }
      return next;
    });
  }, [hasTerminalBackend, terminalIds]);

  const handleConnectionStateChange = useCallback(
    (terminalId: string, state: TerminalConnectionState) => {
      setConnectionStates((prev) => {
        if (prev[terminalId] === state) {
          return prev;
        }
        return {
          ...prev,
          [terminalId]: state,
        };
      });
    },
    []
  );

  const renderMessage = useCallback((message: string) => {
    return (
      <div className="flex flex-1 items-center justify-center px-6 text-center text-sm text-neutral-500 dark:text-neutral-400">
        {message}
      </div>
    );
  }, []);

  const renderTerminalArea = () => {
    if (!isMorphProvider) {
      return renderMessage(
        "Terminals are only available for Morph-based runs."
      );
    }

    if (!xtermBaseUrl) {
      return renderMessage(
        "Waiting for Morph workspace to expose the terminal backend..."
      );
    }

    return (
      <div className="flex flex-col grow min-h-0">
        <div className="flex items-center justify-between gap-3 border-b border-neutral-200 bg-neutral-100/70 px-3 dark:border-neutral-800 dark:bg-neutral-900/40">
          <div className="flex items-center overflow-x-auto py-0.5">
            {terminalIds.length > 0 ? (
              <>
                {terminalIds.map((id, index) => {
                  const state = connectionStates[id] ?? "connecting";
                  const isActive = activeTerminalId === id;
                  const isDeletingThis =
                    isDeletingTerminal && deletingTerminalId === id;
                  return (
                    <div key={id} className="relative pr-2">
                      <button
                        type="button"
                        onClick={() => setActiveTerminalId(id)}
                        className={clsx(
                          "flex items-center gap-2 rounded-md pl-3 pr-8 py-1.5 text-xs font-medium transition-colors",
                          isActive
                            ? "bg-neutral-900 text-neutral-50 dark:bg-neutral-100 dark:text-neutral-900"
                            : "bg-transparent text-neutral-600 hover:bg-neutral-200/70 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-800/60 dark:hover:text-neutral-100"
                        )}
                        title={id}
                      >
                        <span
                          className={clsx(
                            "h-2 w-2 rounded-full",
                            CONNECTION_STATE_COLORS[state]
                          )}
                        />
                        <span className="whitespace-nowrap">
                          Terminal {index + 1}
                        </span>
                      </button>
                      <button
                        type="button"
                        onClick={(event) => {
                          event.stopPropagation();
                          event.preventDefault();
                          if (isDeletingThis || !hasTerminalBackend) {
                            return;
                          }
                          deleteTerminalMutation.mutate(id);
                        }}
                        disabled={isDeletingThis}
                        className={clsx(
                          "absolute right-3 top-1/2 -translate-y-1/2 rounded-full p-1 transition-colors disabled:cursor-not-allowed disabled:opacity-60",
                          isActive
                            ? "text-neutral-100 hover:text-neutral-50 hover:bg-neutral-900/80 dark:text-neutral-700 dark:hover:text-neutral-900 dark:hover:bg-neutral-200"
                            : "text-neutral-500 hover:text-neutral-900 hover:bg-neutral-300 dark:text-neutral-400 dark:hover:text-neutral-100 dark:hover:bg-neutral-700"
                        )}
                        aria-label={`Close terminal ${index + 1}`}
                        title="Close terminal"
                      >
                        {isDeletingThis ? (
                          <span className="text-[10px] font-medium leading-none">
                            …
                          </span>
                        ) : (
                          <X className="h-3 w-3" />
                        )}
                      </button>
                    </div>
                  );
                })}
                <button
                  type="button"
                  onClick={() => {
                    if (!hasTerminalBackend || isCreatingTerminal) {
                      return;
                    }
                    createTerminalMutation.mutate(undefined);
                  }}
                  disabled={!hasTerminalBackend || isCreatingTerminal}
                  className="rounded-full p-1.5 text-neutral-600 transition-colors hover:bg-neutral-200/70 hover:text-neutral-900 disabled:cursor-not-allowed disabled:opacity-60 dark:text-neutral-400 dark:hover:bg-neutral-800/60 dark:hover:text-neutral-100"
                  aria-label="New terminal"
                  title="New terminal"
                >
                  {isCreatingTerminal ? (
                    <span className="text-[10px] font-medium leading-none">
                      …
                    </span>
                  ) : (
                    <Plus className="h-3.5 w-3.5" />
                  )}
                </button>
              </>
            ) : (
              <span className="text-xs text-neutral-500 dark:text-neutral-400">
                No terminals detected yet.
              </span>
            )}
          </div>
          <div className="flex flex-col items-end gap-1 py-2">
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={() => {
                  if (!hasTerminalBackend || isCreatingTerminal) {
                    return;
                  }
                  createTerminalMutation.mutate(undefined);
                }}
                disabled={!hasTerminalBackend || isCreatingTerminal}
                className="flex items-center gap-1 rounded-md border border-neutral-200 px-2 py-1 text-xs font-medium text-neutral-600 transition hover:border-neutral-300 hover:text-neutral-900 disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-300 dark:hover:border-neutral-600 dark:hover:text-neutral-100"
              >
                {isCreatingTerminal ? (
                  "Creating…"
                ) : (
                  <>
                    <Plus className="h-3.5 w-3.5" />
                    <span>New Terminal</span>
                  </>
                )}
              </button>
            </div>
          </div>
        </div>
        {createTerminalErrorMessage ? (
          <span className="text-xs text-red-500 dark:text-red-400">
            {createTerminalErrorMessage}
          </span>
        ) : null}
        {deleteTerminalErrorMessage ? (
          <span className="text-xs text-red-500 dark:text-red-400">
            {deleteTerminalErrorMessage}
          </span>
        ) : null}
        <div className="relative flex-1 min-h-0 bg-neutral-950">
          {tabsQuery.isLoading ? (
            <div className="absolute inset-0 flex items-center justify-center text-sm text-neutral-300">
              Loading terminals…
            </div>
          ) : tabsQuery.isError ? (
            renderMessage(
              tabsQuery.error instanceof Error
                ? tabsQuery.error.message
                : "Unable to load terminals."
            )
          ) : terminalIds.length === 0 ? (
            <div className="flex flex-1 items-center justify-center px-6 py-4 text-center text-sm text-neutral-400">
              No terminal sessions are currently active.
            </div>
          ) : (
            terminalIds.map((id) => (
              <TaskRunTerminalSession
                key={id}
                baseUrl={xtermBaseUrl}
                terminalId={id}
                isActive={activeTerminalId === id}
                onConnectionStateChange={(state) =>
                  handleConnectionStateChange(id, state)
                }
              />
            ))
          )}
        </div>
      </div>
    );
  };

  return (
    <div className="flex flex-col grow bg-neutral-50 dark:bg-black">
      <div className="flex flex-col grow min-h-0 border-l border-neutral-200 dark:border-neutral-800">
        {renderTerminalArea()}
      </div>
    </div>
  );
}
