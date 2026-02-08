import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { getConvex } from "@/lib/utils/get-convex";
import { stackServerAppJs } from "@/lib/utils/stack";
import { api } from "@cmux/convex/api";
import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import { Octokit } from "octokit";

export const githubPrsReviewRouter = new OpenAPIHono();

const GitHubUserSchema = z
  .object({
    login: z.string(),
    id: z.number().optional(),
    avatar_url: z.string().url().optional(),
  })
  .openapi("GithubUser");

const PullRequestReviewSchema = z
  .object({
    id: z.number(),
    user: GitHubUserSchema.optional(),
    state: z.string(),
    body: z.string().nullable().optional(),
    submitted_at: z.string().nullable().optional(),
    html_url: z.string().url().optional(),
  })
  .openapi("GithubPullRequestReview");

const PullRequestReviewCommentSchema = z
  .object({
    id: z.number(),
    body: z.string(),
    path: z.string(),
    line: z.number().nullable().optional(),
    side: z.enum(["LEFT", "RIGHT"]).optional(),
    start_line: z.number().nullable().optional(),
    start_side: z.enum(["LEFT", "RIGHT"]).optional(),
    commit_id: z.string().optional(),
    user: GitHubUserSchema.optional(),
    created_at: z.string().optional(),
    updated_at: z.string().optional(),
    html_url: z.string().url().optional(),
    pull_request_review_id: z.number().nullable().optional(),
    in_reply_to_id: z.number().nullable().optional(),
    diff_hunk: z.string().optional(),
  })
  .openapi("GithubPullRequestReviewComment");

const IssueCommentSchema = z
  .object({
    id: z.number(),
    body: z.string(),
    user: GitHubUserSchema.optional(),
    created_at: z.string().optional(),
    updated_at: z.string().optional(),
    html_url: z.string().url().optional(),
  })
  .openapi("GithubIssueComment");

const GitHubLabelSchema = z
  .object({
    id: z.number().optional(),
    name: z.string(),
    color: z.string().optional(),
    description: z.string().nullable().optional(),
  })
  .openapi("GithubLabel");

const PullRequestDetailsSchema = z
  .object({
    id: z.number().optional(),
    title: z.string().optional(),
    body: z.string().nullable().optional(),
    state: z.enum(["open", "closed"]).optional(),
    draft: z.boolean().optional(),
    merged: z.boolean().optional(),
    html_url: z.string().url().optional(),
    user: GitHubUserSchema.optional(),
    created_at: z.string().optional(),
    updated_at: z.string().optional(),
    requested_reviewers: z.array(GitHubUserSchema).optional(),
    assignees: z.array(GitHubUserSchema).optional(),
    labels: z.array(GitHubLabelSchema).optional(),
  })
  .openapi("GithubPullRequestDetails");

const ReviewDataQuery = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    owner: z.string().min(1).openapi({ description: "GitHub owner/org" }),
    repo: z.string().min(1).openapi({ description: "GitHub repo name" }),
    number: z.coerce.number().min(1).openapi({ description: "PR number" }),
    maxPages: z.coerce
      .number()
      .min(1)
      .max(50)
      .optional()
      .default(10)
      .openapi({ description: "Paginate up to this many pages (default 10)" }),
  })
  .openapi("GithubPrReviewDataQuery");

const ReviewDataResponse = z
  .object({
    repoFullName: z.string(),
    number: z.number(),
    pullRequest: PullRequestDetailsSchema,
    reviews: z.array(PullRequestReviewSchema),
    reviewComments: z.array(PullRequestReviewCommentSchema),
    issueComments: z.array(IssueCommentSchema),
  })
  .openapi("GithubPrReviewDataResponse");

function createOctokit(accessToken: string) {
  return new Octokit({ auth: accessToken });
}

function toRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object") {
    return null;
  }
  return value as Record<string, unknown>;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function mapUser(value: unknown): z.infer<typeof GitHubUserSchema> | undefined {
  const obj = toRecord(value);
  if (!obj) return undefined;
  const login = asString(obj.login);
  if (!login) return undefined;
  const id = asNumber(obj.id);
  const avatar_url = asString(obj.avatar_url);
  return {
    login,
    id,
    avatar_url,
  };
}

async function fetchAllPages<T>(opts: {
  maxPages: number;
  fetchPage: (page: number) => Promise<T[]>;
}): Promise<T[]> {
  const out: T[] = [];
  for (let page = 1; page <= opts.maxPages; page += 1) {
    const chunk = await opts.fetchPage(page);
    out.push(...chunk);
    if (chunk.length < 100) {
      break;
    }
  }
  return out;
}

githubPrsReviewRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/integrations/github/prs/review-data",
    tags: ["Integrations"],
    summary:
      "Fetch GitHub PR review data (reviews, review comments, issue comments) using the user's GitHub OAuth token",
    request: { query: ReviewDataQuery },
    responses: {
      200: {
        description: "OK",
        content: { "application/json": { schema: ReviewDataResponse } },
      },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Not found" },
      500: { description: "Failed to fetch review data" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }

    const [{ accessToken }, githubAccount] = await Promise.all([
      user.getAuthJson(),
      user.getConnectedAccount("github"),
    ]);

    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    if (!githubAccount) {
      return c.json(
        {
          repoFullName: "",
          number: 0,
          reviews: [],
          reviewComments: [],
          issueComments: [],
        },
        401,
      );
    }

    const { accessToken: githubAccessToken } = await githubAccount.getAccessToken();
    if (!githubAccessToken) {
      return c.json(
        {
          repoFullName: "",
          number: 0,
          reviews: [],
          reviewComments: [],
          issueComments: [],
        },
        401,
      );
    }

    const { team, owner, repo, number, maxPages = 10 } = c.req.valid("query");

    await verifyTeamAccess({ req: c.req.raw, teamSlugOrId: team });

    const convex = getConvex({ accessToken });
    const repoFullName = `${owner}/${repo}`;
    const existingPR = await convex.query(api.github_prs.getPullRequest, {
      teamSlugOrId: team,
      repoFullName,
      number,
    });
    if (!existingPR) {
      return c.text("Pull request not found", 404);
    }

    const octokit = createOctokit(githubAccessToken);

    try {
      const [pullRequest, reviews, reviewComments, issueComments] = await Promise.all([
        (async () => {
          const res = await octokit.request(
            "GET /repos/{owner}/{repo}/pulls/{pull_number}",
            { owner, repo, pull_number: number },
          );
          const obj = toRecord(res.data) ?? {};
          const state = asString(obj.state);
          const labelsRaw = Array.isArray(obj.labels) ? obj.labels : [];
          const requestedReviewersRaw = Array.isArray(obj.requested_reviewers)
            ? obj.requested_reviewers
            : [];
          const assigneesRaw = Array.isArray(obj.assignees) ? obj.assignees : [];

          return {
            id: asNumber(obj.id),
            title: asString(obj.title),
            body: asString(obj.body) ?? null,
            state: state === "open" || state === "closed" ? state : undefined,
            draft: typeof obj.draft === "boolean" ? obj.draft : undefined,
            merged: typeof obj.merged === "boolean" ? obj.merged : undefined,
            html_url: asString(obj.html_url),
            user: mapUser(obj.user),
            created_at: asString(obj.created_at),
            updated_at: asString(obj.updated_at),
            requested_reviewers: requestedReviewersRaw
              .map((v: unknown) => mapUser(v))
              .filter((v): v is z.infer<typeof GitHubUserSchema> => Boolean(v)),
            assignees: assigneesRaw
              .map((v: unknown) => mapUser(v))
              .filter((v): v is z.infer<typeof GitHubUserSchema> => Boolean(v)),
            labels: labelsRaw
              .map((value: unknown) => {
                const labelObj = toRecord(value);
                if (!labelObj) return null;
                const name = asString(labelObj.name);
                if (!name) return null;
                const id = asNumber(labelObj.id);
                const color = asString(labelObj.color);
                const description = asString(labelObj.description) ?? null;
                return { id, name, color, description };
              })
              .filter(
                (v): v is NonNullable<typeof v> => Boolean(v),
              ),
          };
        })(),
        fetchAllPages({
          maxPages,
          fetchPage: async (page) => {
            const res = await octokit.request(
              "GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews",
              { owner, repo, pull_number: number, per_page: 100, page },
            );
            const data = Array.isArray(res.data) ? res.data : [];
            return data.map((item: unknown) => {
              const obj = toRecord(item) ?? {};
              return {
                id: asNumber(obj.id) ?? 0,
                user: mapUser(obj.user),
                state: asString(obj.state) ?? "UNKNOWN",
                body: asString(obj.body) ?? null,
                submitted_at: asString(obj.submitted_at) ?? null,
                html_url: asString(obj.html_url),
              };
            });
          },
        }),
        fetchAllPages({
          maxPages,
          fetchPage: async (page) => {
            const res = await octokit.request(
              "GET /repos/{owner}/{repo}/pulls/{pull_number}/comments",
              { owner, repo, pull_number: number, per_page: 100, page },
            );
            const data = Array.isArray(res.data) ? res.data : [];
            return data.map((item: unknown) => {
              const obj = toRecord(item) ?? {};
              const side = asString(obj.side);
              const startSide = asString(obj.start_side);
              return {
                id: asNumber(obj.id) ?? 0,
                body: asString(obj.body) ?? "",
                path: asString(obj.path) ?? "",
                line: asNumber(obj.line) ?? null,
                side:
                  side === "LEFT" || side === "RIGHT" ? side : undefined,
                start_line: asNumber(obj.start_line) ?? null,
                start_side:
                  startSide === "LEFT" || startSide === "RIGHT"
                    ? startSide
                    : undefined,
                commit_id: asString(obj.commit_id),
                user: mapUser(obj.user),
                created_at: asString(obj.created_at),
                updated_at: asString(obj.updated_at),
                html_url: asString(obj.html_url),
                pull_request_review_id: asNumber(obj.pull_request_review_id) ?? null,
                in_reply_to_id: asNumber(obj.in_reply_to_id) ?? null,
                diff_hunk: asString(obj.diff_hunk),
              };
            });
          },
        }),
        fetchAllPages({
          maxPages,
          fetchPage: async (page) => {
            const res = await octokit.request(
              "GET /repos/{owner}/{repo}/issues/{issue_number}/comments",
              { owner, repo, issue_number: number, per_page: 100, page },
            );
            const data = Array.isArray(res.data) ? res.data : [];
            return data.map((item: unknown) => {
              const obj = toRecord(item) ?? {};
              return {
                id: asNumber(obj.id) ?? 0,
                body: asString(obj.body) ?? "",
                user: mapUser(obj.user),
                created_at: asString(obj.created_at),
                updated_at: asString(obj.updated_at),
                html_url: asString(obj.html_url),
              };
            });
          },
        }),
      ]);

      return c.json({
        repoFullName,
        number,
        pullRequest,
        reviews,
        reviewComments,
        issueComments,
      });
    } catch (error) {
      console.error("[github.prs.review-data] Failed to fetch review data:", error);
      return c.text("Failed to fetch review data", 500);
    }
  },
);

const ReviewEventSchema = z.enum(["APPROVE", "REQUEST_CHANGES", "COMMENT"]);

const SubmitReviewBody = z
  .object({
    teamSlugOrId: z.string().min(1),
    owner: z.string().min(1),
    repo: z.string().min(1),
    number: z.number().min(1),
    event: ReviewEventSchema,
    body: z.string().trim().optional(),
    commitId: z.string().trim().optional(),
    comments: z
      .array(
        z.object({
          path: z.string().min(1),
          line: z.number().min(1),
          side: z.enum(["LEFT", "RIGHT"]),
          body: z.string().min(1),
        }),
      )
      .optional(),
  })
  .openapi("GithubSubmitPullRequestReviewRequest");

const SubmitReviewResponse = z
  .object({
    success: z.boolean(),
    reviewId: z.number().optional(),
    message: z.string().optional(),
  })
  .openapi("GithubSubmitPullRequestReviewResponse");

githubPrsReviewRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/integrations/github/prs/reviews",
    tags: ["Integrations"],
    summary:
      "Submit a GitHub pull request review (approve/request changes/comment) with optional inline comments",
    request: {
      body: {
        content: {
          "application/json": {
            schema: SubmitReviewBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        description: "Review submitted",
        content: { "application/json": { schema: SubmitReviewResponse } },
      },
      400: { description: "Invalid request" },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Not found" },
      500: { description: "Failed to submit review" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }

    const [{ accessToken }, githubAccount] = await Promise.all([
      user.getAuthJson(),
      user.getConnectedAccount("github"),
    ]);

    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    if (!githubAccount) {
      return c.json(
        { success: false, message: "GitHub account is not connected" },
        401,
      );
    }

    const { accessToken: githubAccessToken } = await githubAccount.getAccessToken();
    if (!githubAccessToken) {
      return c.json(
        { success: false, message: "GitHub access token unavailable" },
        401,
      );
    }

    const body = c.req.valid("json");
    const { teamSlugOrId, owner, repo, number, event } = body;
    const reviewBody = body.body?.trim();
    const comments = body.comments ?? [];

    if (event === "REQUEST_CHANGES" && (!reviewBody || reviewBody.length === 0)) {
      return c.json(
        { success: false, message: "Request changes requires a non-empty body" },
        400,
      );
    }

    if (event === "COMMENT" && (!reviewBody || reviewBody.length === 0) && comments.length === 0) {
      return c.json(
        { success: false, message: "Provide a review body or at least one inline comment" },
        400,
      );
    }

    await verifyTeamAccess({ req: c.req.raw, teamSlugOrId });

    const convex = getConvex({ accessToken });
    const repoFullName = `${owner}/${repo}`;
    const existingPR = await convex.query(api.github_prs.getPullRequest, {
      teamSlugOrId,
      repoFullName,
      number,
    });
    if (!existingPR) {
      return c.json(
        { success: false, message: "Pull request not found" },
        404,
      );
    }

    const octokit = createOctokit(githubAccessToken);

    try {
      const res = await octokit.request(
        "POST /repos/{owner}/{repo}/pulls/{pull_number}/reviews",
        {
          owner,
          repo,
          pull_number: number,
          event,
          body: reviewBody,
          commit_id: body.commitId?.trim() || existingPR.headSha || undefined,
          comments:
            comments.length > 0
              ? comments.map((comment) => ({
                  path: comment.path,
                  line: comment.line,
                  side: comment.side,
                  body: comment.body,
                }))
              : undefined,
        },
      );

      const respObj = toRecord(res.data);
      const reviewId = respObj ? asNumber(respObj.id) : undefined;

      return c.json({ success: true, reviewId });
    } catch (error) {
      console.error("[github.prs.reviews] Failed to submit review:", error);
      const message =
        error instanceof Error ? error.message : "Failed to submit review";
      return c.json({ success: false, message }, 500);
    }
  },
);

const CreateIssueCommentBody = z
  .object({
    teamSlugOrId: z.string().min(1),
    owner: z.string().min(1),
    repo: z.string().min(1),
    number: z.number().min(1),
    body: z.string().trim().min(1),
  })
  .openapi("GithubCreateIssueCommentRequest");

const CreateIssueCommentResponse = z
  .object({
    success: z.boolean(),
    commentId: z.number().optional(),
    message: z.string().optional(),
  })
  .openapi("GithubCreateIssueCommentResponse");

githubPrsReviewRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/integrations/github/prs/issue-comments",
    tags: ["Integrations"],
    summary: "Create a GitHub issue comment on a pull request (PR conversation comment)",
    request: {
      body: {
        content: {
          "application/json": {
            schema: CreateIssueCommentBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        description: "Comment created",
        content: { "application/json": { schema: CreateIssueCommentResponse } },
      },
      400: { description: "Invalid request" },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Not found" },
      500: { description: "Failed to create comment" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }

    const [{ accessToken }, githubAccount] = await Promise.all([
      user.getAuthJson(),
      user.getConnectedAccount("github"),
    ]);

    if (!accessToken) {
      return c.text("Unauthorized", 401);
    }

    if (!githubAccount) {
      return c.json(
        { success: false, message: "GitHub account is not connected" },
        401,
      );
    }

    const { accessToken: githubAccessToken } = await githubAccount.getAccessToken();
    if (!githubAccessToken) {
      return c.json(
        { success: false, message: "GitHub access token unavailable" },
        401,
      );
    }

    const body = c.req.valid("json");
    const { teamSlugOrId, owner, repo, number } = body;

    await verifyTeamAccess({ req: c.req.raw, teamSlugOrId });

    const convex = getConvex({ accessToken });
    const repoFullName = `${owner}/${repo}`;
    const existingPR = await convex.query(api.github_prs.getPullRequest, {
      teamSlugOrId,
      repoFullName,
      number,
    });
    if (!existingPR) {
      return c.json(
        { success: false, message: "Pull request not found" },
        404,
      );
    }

    const octokit = createOctokit(githubAccessToken);

    try {
      const res = await octokit.request(
        "POST /repos/{owner}/{repo}/issues/{issue_number}/comments",
        { owner, repo, issue_number: number, body: body.body },
      );

      const respObj = toRecord(res.data);
      const commentId = respObj ? asNumber(respObj.id) : undefined;
      return c.json({ success: true, commentId });
    } catch (error) {
      console.error("[github.prs.issue-comments] Failed to create comment:", error);
      const message =
        error instanceof Error ? error.message : "Failed to create comment";
      return c.json({ success: false, message }, 500);
    }
  },
);
