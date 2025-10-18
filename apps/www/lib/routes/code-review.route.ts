import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import { stackServerAppJs } from "../utils/stack";
import {
  getConvexHttpActionBaseUrl,
  startCodeReviewJob,
} from "../services/code-review/start-code-review";

const CODE_REVIEW_STATES = ["pending", "running", "completed", "failed"] as const;

const CodeReviewJobSchema = z.object({
  jobId: z.string(),
  teamId: z.string().nullable(),
  repoFullName: z.string(),
  repoUrl: z.string(),
  prNumber: z.number(),
  commitRef: z.string(),
  requestedByUserId: z.string(),
  state: z.enum(CODE_REVIEW_STATES),
  createdAt: z.number(),
  updatedAt: z.number(),
  startedAt: z.number().nullable(),
  completedAt: z.number().nullable(),
  sandboxInstanceId: z.string().nullable(),
  errorCode: z.string().nullable(),
  errorDetail: z.string().nullable(),
  codeReviewOutput: z.record(z.string(), z.any()).nullable(),
});

const StartBodySchema = z
  .object({
    teamSlugOrId: z.string().optional(),
    githubLink: z.string().url(),
    prNumber: z.number().int().positive(),
    commitRef: z.string().optional(),
    force: z.boolean().optional(),
  })
  .openapi("CodeReviewStartBody");

const StartResponseSchema = z
  .object({
    job: CodeReviewJobSchema,
    deduplicated: z.boolean(),
  })
  .openapi("CodeReviewStartResponse");

type CodeReviewStartBody = z.infer<typeof StartBodySchema>;

export const codeReviewRouter = new OpenAPIHono();

codeReviewRouter.openapi(
  createRoute({
    method: "post",
    path: "/code-review/start",
    tags: ["Code Review"],
    summary: "Start an automated code review for a pull request",
    request: {
      body: {
        content: {
          "application/json": {
            schema: StartBodySchema,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: StartResponseSchema,
          },
        },
        description: "Job created or reused",
      },
      401: { description: "Unauthorized" },
      500: { description: "Failed to start code review" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.json({ error: "Unauthorized" }, 401);
    }
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      return c.json({ error: "Unauthorized" }, 401);
    }

    const body = c.req.valid("json") as CodeReviewStartBody;
    const convexHttpBase = getConvexHttpActionBaseUrl();
    if (!convexHttpBase) {
      return c.json({ error: "Convex HTTP base URL is not configured" }, 500);
    }
    const { job, deduplicated, backgroundTask } = await startCodeReviewJob({
      accessToken,
      callbackBaseUrl: convexHttpBase,
      payload: {
        teamSlugOrId: body.teamSlugOrId,
        githubLink: body.githubLink,
        prNumber: body.prNumber,
        commitRef: body.commitRef,
        force: body.force,
      },
      request: c.req.raw,
    });

    if (backgroundTask) {
      void backgroundTask;
    }

    return c.json(
      {
        job,
        deduplicated,
      },
      200,
    );
  },
);
