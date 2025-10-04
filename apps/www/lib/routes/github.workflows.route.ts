import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { getConvex } from "../utils/get-convex";

export const githubWorkflowsRouter = new OpenAPIHono();

const Query = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    installationId: z.coerce
      .number()
      .optional()
      .openapi({ description: "GitHub App installation ID to query" }),
    repoFullName: z
      .string()
      .optional()
      .openapi({ description: "Filter by repository (owner/repo format)" }),
    workflowId: z.coerce
      .number()
      .optional()
      .openapi({ description: "Filter by workflow ID" }),
    limit: z.coerce.number().optional().default(50).openapi({
      description: "Maximum number of results to return (default 50, max 100)",
    }),
  })
  .strict();

const WorkflowRunSchema = z.object({
  _id: z.string(),
  _creationTime: z.number(),
  provider: z.literal("github"),
  installationId: z.number(),
  repositoryId: z.number().optional(),
  repoFullName: z.string(),
  runId: z.number(),
  runNumber: z.number(),
  teamId: z.string(),
  workflowId: z.number(),
  workflowName: z.string(),
  name: z.string().optional(),
  event: z.string(),
  status: z
    .enum(["queued", "in_progress", "completed", "pending", "waiting"])
    .optional(),
  conclusion: z
    .enum([
      "success",
      "failure",
      "neutral",
      "cancelled",
      "skipped",
      "timed_out",
      "action_required",
    ])
    .optional(),
  headBranch: z.string().optional(),
  headSha: z.string().optional(),
  htmlUrl: z.string().optional(),
  createdAt: z.number().optional(),
  updatedAt: z.number().optional(),
  runStartedAt: z.number().optional(),
  runCompletedAt: z.number().optional(),
  runDuration: z.number().optional(),
  actorLogin: z.string().optional(),
  actorId: z.number().optional(),
  triggeringPrNumber: z.number().optional(),
});

const WorkflowRunsResponse = z.object({
  runs: z.array(WorkflowRunSchema),
  total: z.number(),
});

githubWorkflowsRouter.openapi(
  createRoute({
    method: "get",
    path: "/api/integrations/github/workflow-runs",
    summary: "Get GitHub Actions workflow runs",
    description:
      "Retrieve GitHub Actions workflow runs for a team, with optional filtering by repository and workflow",
    request: {
      query: Query,
    },
    responses: {
      200: {
        description: "Workflow runs retrieved successfully",
        content: {
          "application/json": {
            schema: WorkflowRunsResponse,
          },
        },
      },
      400: {
        description: "Bad request - missing or invalid parameters",
      },
      401: {
        description: "Unauthorized - invalid or missing authentication",
      },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { team, repoFullName, workflowId, limit = 50 } = c.req.valid("query");

    const convex = getConvex({ accessToken });

    try {
      // Get workflow runs from Convex
      const runs = await convex.query(api.github_workflows.getWorkflowRuns, {
        teamId: team,
        repoFullName,
        workflowId,
        limit: Math.min(limit, 100), // Cap at 100
      });

      return c.json({
        runs: runs || [],
        total: runs?.length || 0,
      });
    } catch (error) {
      console.error("Error fetching workflow runs:", error);
      return c.json({ error: "Failed to fetch workflow runs" }, 500);
    }
  },
);

// Get workflow runs for a specific PR
const PrQuery = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    repoFullName: z
      .string()
      .openapi({ description: "Repository (owner/repo format)" }),
    prNumber: z.coerce.number().openapi({ description: "Pull request number" }),
    limit: z.coerce.number().optional().default(20).openapi({
      description: "Maximum number of results to return (default 20, max 50)",
    }),
  })
  .strict();

githubWorkflowsRouter.openapi(
  createRoute({
    method: "get",
    path: "/api/integrations/github/workflow-runs/pr",
    summary: "Get GitHub Actions workflow runs for a PR",
    description:
      "Retrieve GitHub Actions workflow runs that were triggered by a specific pull request",
    request: {
      query: PrQuery,
    },
    responses: {
      200: {
        description: "Workflow runs for PR retrieved successfully",
        content: {
          "application/json": {
            schema: WorkflowRunsResponse,
          },
        },
      },
      400: {
        description: "Bad request - missing or invalid parameters",
      },
      401: {
        description: "Unauthorized - invalid or missing authentication",
      },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { team, repoFullName, prNumber, limit = 20 } = c.req.valid("query");

    const convex = getConvex({ accessToken });

    try {
      // Get workflow runs for PR from Convex
      const runs = await convex.query(
        api.github_workflows.getWorkflowRunsForPr,
        {
          teamId: team,
          repoFullName,
          prNumber,
          limit: Math.min(limit, 50), // Cap at 50
        },
      );

      return c.json({
        runs: runs || [],
        total: runs?.length || 0,
      });
    } catch (error) {
      console.error("Error fetching workflow runs for PR:", error);
      return c.json({ error: "Failed to fetch workflow runs for PR" }, 500);
    }
  },
);
