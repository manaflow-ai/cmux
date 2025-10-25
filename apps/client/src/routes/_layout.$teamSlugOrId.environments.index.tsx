import { FloatingPane } from "@/components/floating-pane";
import { TitleBar } from "@/components/TitleBar";
import {
  clearPendingEnvironment,
  usePendingEnvironments,
  type PendingEnvironment,
} from "@/lib/pendingEnvironmentsStore";
import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { api } from "@cmux/convex/api";
import { convexQuery } from "@convex-dev/react-query";
import { useSuspenseQuery } from "@tanstack/react-query";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { formatDistanceToNow } from "date-fns";
import {
  Calendar,
  Eye,
  GitBranch,
  Play,
  Plus,
  RotateCcw,
  Server,
  Trash2,
} from "lucide-react";
import { useCallback } from "react";

export const Route = createFileRoute("/_layout/$teamSlugOrId/environments/")({
  loader: async ({ params }) => {
    await convexQueryClient.queryClient.ensureQueryData(
      convexQuery(api.environments.list, {
        teamSlugOrId: params.teamSlugOrId,
      })
    );
  },
  component: EnvironmentsListPage,
});

function EnvironmentsListPage() {
  const { teamSlugOrId } = Route.useParams();
  const navigate = useNavigate();

  const { data: environments } = useSuspenseQuery(
    convexQuery(api.environments.list, {
      teamSlugOrId,
    })
  );

  const pendingEnvironments = usePendingEnvironments(teamSlugOrId);

  const startNewEnvironment = useCallback(() => {
    void navigate({
      to: "/$teamSlugOrId/environments/new",
      params: { teamSlugOrId },
      search: {
        step: "select",
        selectedRepos: undefined,
        connectionLogin: undefined,
        repoSearch: undefined,
        instanceId: undefined,
        snapshotId: undefined,
        pendingId: undefined,
      },
    });
  }, [navigate, teamSlugOrId]);

  const handleResumePending = (pending: PendingEnvironment) => {
    void navigate({
      to: "/$teamSlugOrId/environments/new",
      params: { teamSlugOrId },
      search: {
        step: pending.step,
        selectedRepos:
          pending.selectedRepos.length > 0 ? pending.selectedRepos : undefined,
        connectionLogin: pending.connectionLogin ?? undefined,
        repoSearch: pending.repoSearch ?? undefined,
        instanceId: pending.instanceId,
        snapshotId: pending.snapshotId,
        pendingId: pending.id,
      },
    });
  };

  const handleDiscardPending = (pending: PendingEnvironment) => {
    clearPendingEnvironment(teamSlugOrId, pending.id);
  };

  return (
    <FloatingPane header={<TitleBar title="Environments" />}>
      <div className="p-6 space-y-6">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-neutral-900 dark:text-neutral-100">
            Your Environments
          </h2>
          <button
            type="button"
            onClick={startNewEnvironment}
            className="inline-flex items-center gap-2 rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
          >
            <Plus className="h-4 w-4" />
            New environment
          </button>
        </div>

        {pendingEnvironments.length > 0 ? (
          <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
            {pendingEnvironments.map((pending) => {
              const pendingName =
                pending.envName && pending.envName.trim().length > 0
                  ? pending.envName
                  : "Untitled environment";
              const pendingUpdatedLabel = formatDistanceToNow(
                new Date(pending.updatedAt),
                {
                  addSuffix: true,
                }
              );

              return (
                <div
                  key={pending.id}
                  className="flex h-full flex-col rounded-lg border border-dashed border-neutral-300 bg-white p-4 dark:border-neutral-700 dark:bg-neutral-950"
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="flex items-center gap-2">
                      <Server className="h-5 w-5 text-neutral-600 dark:text-neutral-400" />
                      <h3 className="text-base font-semibold text-neutral-900 dark:text-neutral-50">
                        {pendingName}
                      </h3>
                    </div>
                    <span className="inline-flex items-center rounded-full bg-neutral-100 px-2.5 py-0.5 text-[11px] font-semibold uppercase tracking-wide text-neutral-600 dark:bg-neutral-900 dark:text-neutral-300">
                      Draft
                    </span>
                  </div>

                  <div className="mt-3 space-y-3 text-sm">
                    <div>
                      <div className="mb-1 flex items-center gap-1 text-xs text-neutral-500 dark:text-neutral-500">
                        <GitBranch className="h-3 w-3" />
                        Repositories
                      </div>
                      {pending.selectedRepos.length > 0 ? (
                        <div className="flex flex-wrap gap-1">
                          {pending.selectedRepos.slice(0, 3).map((repo) => (
                            <span
                              key={repo}
                              className="inline-flex items-center rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-700 dark:bg-neutral-900 dark:text-neutral-200"
                            >
                              {repo.split("/")[1] || repo}
                            </span>
                          ))}
                          {pending.selectedRepos.length > 3 ? (
                            <span className="inline-flex items-center rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-700 dark:bg-neutral-900 dark:text-neutral-200">
                              +{pending.selectedRepos.length - 3}
                            </span>
                          ) : null}
                        </div>
                      ) : (
                        <p className="rounded-md bg-neutral-50 px-3 py-1 text-xs text-neutral-700 dark:bg-neutral-900/70 dark:text-neutral-200">
                          No repositories selected yet
                        </p>
                      )}
                    </div>
                    <div className="flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-500">
                      <Calendar className="h-3.5 w-3.5" />
                      Updated {pendingUpdatedLabel}
                    </div>
                  </div>

                  <div className="mt-auto flex gap-2 border-t border-neutral-100 pt-3 dark:border-neutral-900">
                    <button
                      type="button"
                      onClick={() => handleDiscardPending(pending)}
                      className="inline-flex flex-1 cursor-pointer items-center justify-center gap-1.5 rounded-md border border-neutral-200 bg-white px-3 py-1.5 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:text-neutral-300 dark:hover:bg-neutral-900"
                    >
                      <Trash2 className="h-4 w-4" />
                      Discard
                    </button>
                    <button
                      type="button"
                      onClick={() => handleResumePending(pending)}
                      className="inline-flex flex-1 cursor-pointer items-center justify-center gap-1.5 rounded-md bg-neutral-900 px-3 py-1.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                    >
                      <RotateCcw className="h-4 w-4" />
                      Resume
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        ) : null}

        {pendingEnvironments.length > 0 && (environments?.length ?? 0) > 0 ? (
          <div className="my-6 border-t border-neutral-200 dark:border-neutral-800" />
        ) : null}

        {environments && environments.length > 0 ? (
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            {environments.map((env) => (
              <div
                key={env._id}
                className="group relative flex flex-col rounded-lg border border-neutral-200 bg-white p-4 transition-shadow hover:shadow-md dark:border-neutral-800 dark:bg-neutral-950"
              >
                <div className="flex flex-col grow">
                  <div className="mb-3 flex items-start justify-between">
                    <div className="flex items-center gap-2">
                      <Server className="h-5 w-5 text-neutral-600 dark:text-neutral-400" />
                      <h3 className="font-medium text-neutral-900 dark:text-neutral-100">
                        {env.name}
                      </h3>
                    </div>
                  </div>

                  {env.description && (
                    <p className="mb-3 text-sm text-neutral-600 dark:text-neutral-400 line-clamp-2">
                      {env.description}
                    </p>
                  )}

                  {env.selectedRepos && env.selectedRepos.length > 0 && (
                    <div className="mb-3">
                      <div className="mb-1 flex items-center gap-1 text-xs text-neutral-500 dark:text-neutral-500">
                        <GitBranch className="h-3 w-3" />
                        Repositories
                      </div>
                      <div className="flex flex-wrap gap-1">
                        {env.selectedRepos.slice(0, 3).map((repo) => (
                          <span
                            key={repo}
                            className="inline-flex items-center rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-700 dark:bg-neutral-900 dark:text-neutral-300"
                          >
                            {repo.split("/")[1] || repo}
                          </span>
                        ))}
                        {env.selectedRepos.length > 3 && (
                          <span className="inline-flex items-center rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-700 dark:bg-neutral-900 dark:text-neutral-300">
                            +{env.selectedRepos.length - 3}
                          </span>
                        )}
                      </div>
                    </div>
                  )}

                  <div className="flex items-center gap-3 text-xs text-neutral-500 dark:text-neutral-500">
                    <div className="flex items-center gap-1">
                      <Calendar className="h-3 w-3" />
                      {formatDistanceToNow(new Date(env.createdAt), {
                        addSuffix: true,
                      })}
                    </div>
                  </div>
                </div>

                <div className="mt-3 border-t border-neutral-100 pt-3 dark:border-neutral-900">
                  <div className="mb-3 text-xs text-neutral-500 dark:text-neutral-500">
                    Snapshot ID: {env.morphSnapshotId}
                  </div>
                  <div className="flex gap-2">
                    <Link
                      to="/$teamSlugOrId/environments/$environmentId"
                      params={{ teamSlugOrId, environmentId: env._id }}
                      search={{
                        step: undefined,
                        selectedRepos: undefined,
                        connectionLogin: undefined,
                        repoSearch: undefined,
                        instanceId: undefined,
                        snapshotId: env.morphSnapshotId ?? undefined,
                      }}
                      className="inline-flex flex-1 items-center justify-center gap-1.5 rounded-md border border-neutral-200 bg-white px-3 py-1.5 text-sm font-medium text-neutral-700 hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:text-neutral-300 dark:hover:bg-neutral-900"
                    >
                      <Eye className="h-4 w-4" />
                      View
                    </Link>
                    <Link
                      to="/$teamSlugOrId/dashboard"
                      params={{ teamSlugOrId }}
                      search={{ environmentId: env._id }}
                      className="inline-flex flex-1 items-center justify-center gap-1.5 rounded-md bg-neutral-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                    >
                      <Play className="h-4 w-4" />
                      Launch
                    </Link>
                  </div>
                </div>
              </div>
            ))}
          </div>
        ) : null}

        {pendingEnvironments.length === 0 && (!environments || environments.length === 0) ? (
          <div className="py-12 text-center">
            <div className="mx-auto mb-4 flex h-16 w-16 items-center justify-center rounded-lg bg-neutral-100 dark:bg-neutral-900">
              <Server className="h-8 w-8 text-neutral-400 dark:text-neutral-600" />
            </div>
            <h3 className="mb-2 text-lg font-medium text-neutral-900 dark:text-neutral-100">
              No environments yet
            </h3>
            <p className="mx-auto mb-6 max-w-md text-sm text-neutral-600 dark:text-neutral-400">
              Create your first environment to save and reuse development configurations across your team.
            </p>
            <button
              type="button"
              onClick={startNewEnvironment}
              className="inline-flex items-center gap-2 rounded-md bg-neutral-900 px-4 py-2 text-sm font-medium text-white hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
            >
              <Plus className="h-4 w-4" />
              Create first environment
            </button>
          </div>
        ) : null}
      </div>
    </FloatingPane>
  );
}
