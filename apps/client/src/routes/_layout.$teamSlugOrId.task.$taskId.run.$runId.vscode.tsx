import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { convexQuery } from "@convex-dev/react-query";
import { useSuspenseQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import z from "zod";
import { TaskRunTerminalSurface } from "@/components/TaskRunTerminalSurface";
import { WorkspaceLoadingIndicator } from "@/components/workspace-loading-indicator";
import { toProxyWorkspaceUrl } from "@/lib/toProxyWorkspaceUrl";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
});

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/vscode"
)({
  component: VSCodeComponent,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
        runId: params.runId,
      };
    },
  },
  loader: async (opts) => {
    await opts.context.queryClient.ensureQueryData(
      convexQuery(api.taskRuns.get, {
        teamSlugOrId: opts.params.teamSlugOrId,
        id: opts.params.runId,
      })
    );
  },
});

function VSCodeComponent() {
  const { runId: taskRunId, teamSlugOrId } = Route.useParams();
  const taskRun = useSuspenseQuery(
    convexQuery(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    })
  );

  const workspaceUrl = taskRun?.data?.vscode?.workspaceUrl
    ? toProxyWorkspaceUrl(taskRun.data.vscode.workspaceUrl)
    : null;
  const hasWorkspace = workspaceUrl !== null;

  return (
    <div className="flex flex-col grow bg-neutral-50 dark:bg-black">
      <div className="flex flex-col grow min-h-0 border-l border-neutral-200 dark:border-neutral-800">
        {hasWorkspace ? (
          <TaskRunTerminalSurface
            workspaceUrl={workspaceUrl}
            key={workspaceUrl}
          />
        ) : (
          <div className="flex flex-1 items-center justify-center">
            <WorkspaceLoadingIndicator variant="vscode" status="loading" />
          </div>
        )}
      </div>
    </div>
  );
}
