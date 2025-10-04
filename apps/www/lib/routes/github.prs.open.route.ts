import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { getConvex } from "@/lib/utils/get-convex";
import { stackServerAppJs } from "@/lib/utils/stack";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import {
  reconcilePullRequestRecords,
  type AggregatePullRequestSummary,
  type PullRequestActionResult,
  type RunPullRequestState,
  type StoredPullRequestInfo,
} from "@cmux/shared/pull-request-state";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import { Octokit } from "octokit";

type TaskDoc = Doc<"tasks">;
type TaskRunDoc = Doc<"taskRuns">;

type GitHubPrBasic = {
  number: number;
  html_url: string;
  state: string;
  draft?: boolean;
};

type GitHubPrDetail = GitHubPrBasic & {
  merged_at: string | null;
  node_id: string;
};

type ConvexClient = ReturnType<typeof getConvex>;
type OctokitThrottleOptions = {
  method?: string;
  url?: string;
};

const runPullRequestStates = [
  "none",
  "draft",
  "open",
  "merged",
  "closed",
  "unknown",
] as const;

const taskMergeStatuses = [
  "none",
  "pr_draft",
  "pr_open",
  "pr_merged",
  "pr_closed",
] as const;

const PullRequestActionResultSchema = z.object({
  repoFullName: z.string(),
  url: z.string().url().optional(),
  number: z.number().optional(),
  state: z.enum(runPullRequestStates),
  isDraft: z.boolean().optional(),
  error: z.string().optional(),
});

const AggregatePullRequestSummarySchema = z.object({
  state: z.enum(runPullRequestStates),
  isDraft: z.boolean(),
  mergeStatus: z.enum(taskMergeStatuses),
  url: z.string().url().optional(),
  number: z.number().optional(),
});

const OpenPullRequestBody = z
  .object({
    teamSlugOrId: z.string(),
    taskRunId: typedZid("taskRuns"),
  })
  .openapi("GithubOpenPrRequest");

const MergePullRequestBody = z
  .object({
    teamSlugOrId: z.string(),
    taskRunId: typedZid("taskRuns"),
    method: z.enum(["squash", "rebase", "merge"]),
  })
  .openapi("GithubMergePrRequest");

const ClosePullRequestBody = z
  .object({
    teamSlugOrId: z.string(),
    owner: z.string(),
    repo: z.string(),
    number: z.number(),
  })
  .openapi("GithubClosePrRequest");

const MergePullRequestSimpleBody = z
  .object({
    teamSlugOrId: z.string(),
    owner: z.string(),
    repo: z.string(),
    number: z.number(),
    method: z.enum(["squash", "rebase", "merge"]),
  })
  .openapi("GithubMergePrSimpleRequest");

const OpenPullRequestResponse = z
  .object({
    success: z.boolean(),
    results: z.array(PullRequestActionResultSchema),
    aggregate: AggregatePullRequestSummarySchema,
    error: z.string().optional(),
  })
  .openapi("GithubOpenPrResponse");

export const githubPrsOpenRouter = new OpenAPIHono();

githubPrsOpenRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/integrations/github/prs/open",
    tags: ["Integrations"],
    summary:
      "Create or update GitHub pull requests for a task run using the user's GitHub OAuth token",
    request: {
      body: {
        content: {
          "application/json": {
            schema: OpenPullRequestBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        description: "PRs created or updated",
        content: {
          "application/json": {
            schema: OpenPullRequestResponse,
          },
        },
      },
      400: { description: "Invalid request" },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Task run not found" },
      500: { description: "Failed to create or update PRs" },
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
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "GitHub account is not connected",
        },
        401,
      );
    }

    const { accessToken: githubAccessToken } = await githubAccount.getAccessToken();
    if (!githubAccessToken) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "GitHub access token unavailable",
        },
        401,
      );
    }

    const body = c.req.valid("json");
    const { teamSlugOrId, taskRunId } = body;

    await verifyTeamAccess({ req: c.req.raw, teamSlugOrId });

    const convex = getConvex({ accessToken });

    const run = await convex.query(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    });

    if (!run) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "Task run not found",
        },
        404,
      );
    }

    const task = await convex.query(api.tasks.getById, {
      teamSlugOrId,
      id: run.taskId,
    });

    if (!task) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "Task not found",
        },
        404,
      );
    }

    const branchName = run.newBranch?.trim();
    if (!branchName) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "Missing branch name for run",
        },
        400,
      );
    }

    const repoFullNames = await collectRepoFullNamesForRun({
      convex,
      run,
      task,
      teamSlugOrId,
    });

    if (repoFullNames.length === 0) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "No repositories configured for this run",
        },
        400,
      );
    }

    const baseBranch = task.baseBranch?.trim() || "main";
    const title = task.pullRequestTitle || task.text || "cmux changes";
    const truncatedTitle =
      title.length > 72 ? `${title.slice(0, 69)}...` : title;
    const description =
      task.text ||
      `## Summary\n\n${title}`;

    const existingByRepo = new Map(
      (run.pullRequests ?? []).map(
        (record) => [record.repoFullName, record] as const,
      ),
    );

    const octokit = createOctokit(githubAccessToken);

    const results = await Promise.all(
      repoFullNames.map(async (repoFullName) => {
        try {
          const split = splitRepoFullName(repoFullName);
          if (!split) {
            throw new Error(`Invalid repository name: ${repoFullName}`);
          }

          const { owner, repo } = split;
          const existingRecord = existingByRepo.get(repoFullName);
          const existingNumber = existingRecord?.number;

          let detail = await loadPullRequestDetail({
            octokit,
            repoFullName,
            owner,
            repo,
            branchName,
            number: existingNumber,
          });

          if (!detail) {
            const created = await createReadyPullRequest({
              octokit,
              owner,
              repo,
              title: truncatedTitle,
              head: branchName,
              base: baseBranch,
              body: description,
            });
            detail = await fetchPullRequestDetail({
              octokit,
              owner,
              repo,
              number: created.number,
            });
          } else if (detail.draft) {
            await markPullRequestReady({
              octokit,
              owner,
              repo,
              number: detail.number,
              nodeId: detail.node_id,
            });
            detail = await fetchPullRequestDetail({
              octokit,
              owner,
              repo,
              number: detail.number,
            });
          }

          return toPullRequestActionResult(repoFullName, detail);
        } catch (error) {
          const message =
            error instanceof Error ? error.message : String(error);
          return {
            repoFullName,
            url: undefined,
            number: undefined,
            state: "none" as const,
            isDraft: undefined,
            error: message,
          } satisfies PullRequestActionResult;
        }
      }),
    );

    try {
      const persisted = await persistPullRequestResults({
        convex,
        teamSlugOrId,
        run,
        task,
        repoFullNames,
        results,
      });

      const errors = results
        .filter((result) => result.error)
        .map((result) => `${result.repoFullName}: ${result.error}`);

      return c.json({
        success: errors.length === 0,
        results,
        aggregate: persisted.aggregate,
        error: errors.length > 0 ? errors.join("; ") : undefined,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return c.json(
        {
          success: false,
          results,
          aggregate: emptyAggregate(),
          error: message,
        },
        500,
      );
    }
  },
);

githubPrsOpenRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/integrations/github/prs/merge",
    tags: ["Integrations"],
    summary: "Merge GitHub pull requests for a task run using the user's GitHub OAuth token",
    request: {
      body: {
        content: {
          "application/json": {
            schema: MergePullRequestBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        description: "PRs merged",
        content: {
          "application/json": {
            schema: OpenPullRequestResponse,
          },
        },
      },
      400: { description: "Invalid request" },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      404: { description: "Task run not found" },
      500: { description: "Failed to merge PRs" },
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
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "GitHub account is not connected",
        },
        401,
      );
    }

    const { accessToken: githubAccessToken } = await githubAccount.getAccessToken();
    if (!githubAccessToken) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "GitHub access token unavailable",
        },
        401,
      );
    }

    const body = c.req.valid("json");
    const { teamSlugOrId, taskRunId, method } = body;

    await verifyTeamAccess({ req: c.req.raw, teamSlugOrId });

    const convex = getConvex({ accessToken });

    const run = await convex.query(api.taskRuns.get, {
      teamSlugOrId,
      id: taskRunId,
    });

    if (!run) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "Task run not found",
        },
        404,
      );
    }

    const task = await convex.query(api.tasks.getById, {
      teamSlugOrId,
      id: run.taskId,
    });

    if (!task) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "Task not found",
        },
        404,
      );
    }

    const branchName = run.newBranch?.trim();
    if (!branchName) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "Missing branch name for run",
        },
        400,
      );
    }

    const repoFullNames = await collectRepoFullNamesForRun({
      convex,
      run,
      task,
      teamSlugOrId,
    });

    if (repoFullNames.length === 0) {
      return c.json(
        {
          success: false,
          results: [],
          aggregate: emptyAggregate(),
          error: "No repositories configured for this run",
        },
        400,
      );
    }

    const title = task.pullRequestTitle || task.text || "cmux changes";
    const truncatedTitle =
      title.length > 72 ? `${title.slice(0, 69)}...` : title;
    const commitMessage = `Merged by cmux for task ${String(task._id)}.`;

    const existingByRepo = new Map(
      (run.pullRequests ?? []).map(
        (record) => [record.repoFullName, record] as const,
      ),
    );

    const octokit = createOctokit(githubAccessToken);

    const results = await Promise.all(
      repoFullNames.map(async (repoFullName) => {
        try {
          const split = splitRepoFullName(repoFullName);
          if (!split) {
            throw new Error(`Invalid repository name: ${repoFullName}`);
          }

          const { owner, repo } = split;
          const existingRecord = existingByRepo.get(repoFullName);

          let detail = await loadPullRequestDetail({
            octokit,
            repoFullName,
            owner,
            repo,
            branchName,
            number: existingRecord?.number,
          });

          if (!detail) {
            throw new Error("Pull request not found for this branch");
          }

          if (detail.draft) {
            await markPullRequestReady({
              octokit,
              owner,
              repo,
              number: detail.number,
              nodeId: detail.node_id,
            });
            detail = await fetchPullRequestDetail({
              octokit,
              owner,
              repo,
              number: detail.number,
            });
          }

          if (
            (detail.state ?? "").toLowerCase() === "closed" &&
            !detail.merged_at
          ) {
            await reopenPullRequest({
              octokit,
              owner,
              repo,
              number: detail.number,
            });
            detail = await fetchPullRequestDetail({
              octokit,
              owner,
              repo,
              number: detail.number,
            });
          }

          await mergePullRequest({
            octokit,
            owner,
            repo,
            number: detail.number,
            method,
            commitTitle: truncatedTitle,
            commitMessage,
          });

          const mergedDetail = await fetchPullRequestDetail({
            octokit,
            owner,
            repo,
            number: detail.number,
          });

          return toPullRequestActionResult(repoFullName, {
            ...mergedDetail,
            merged_at:
              mergedDetail.merged_at ?? new Date().toISOString(),
          });
        } catch (error) {
          const message =
            error instanceof Error ? error.message : String(error);
          return {
            repoFullName,
            url: undefined,
            number: undefined,
            state: "unknown" as const,
            isDraft: undefined,
            error: message,
          } satisfies PullRequestActionResult;
        }
      }),
    );

    try {
      const persisted = await persistPullRequestResults({
        convex,
        teamSlugOrId,
        run,
        task,
        repoFullNames,
        results,
      });

      const errors = results
        .filter((result) => result.error)
        .map((result) => `${result.repoFullName}: ${result.error}`);

      return c.json({
        success: errors.length === 0,
        results,
        aggregate: persisted.aggregate,
        error: errors.length > 0 ? errors.join("; ") : undefined,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return c.json(
        {
          success: false,
          results,
          aggregate: emptyAggregate(),
          error: message,
        },
        500,
      );
    }
  },
);

githubPrsOpenRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/integrations/github/prs/close",
    tags: ["Integrations"],
    summary: "Close a GitHub pull request using the user's GitHub OAuth token",
    request: {
      body: {
        content: {
          "application/json": {
            schema: ClosePullRequestBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        description: "PR closed successfully",
        content: {
          "application/json": {
            schema: z.object({
              success: z.boolean(),
              message: z.string(),
            }),
          },
        },
      },
      400: { description: "Invalid request" },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      500: { description: "Failed to close PR" },
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
          success: false,
          message: "GitHub account is not connected",
        },
        401,
      );
    }

    const { accessToken: githubAccessToken } = await githubAccount.getAccessToken();
    if (!githubAccessToken) {
      return c.json(
        {
          success: false,
          message: "GitHub access token unavailable",
        },
        401,
      );
    }

    const body = c.req.valid("json");
    const { teamSlugOrId, owner, repo, number } = body;

    await verifyTeamAccess({ req: c.req.raw, teamSlugOrId });

    const octokit = createOctokit(githubAccessToken);

    try {
      await closePullRequest({
        octokit,
        owner,
        repo,
        number,
      });

      return c.json({
        success: true,
        message: `PR #${number} closed successfully`,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return c.json(
        {
          success: false,
          message: `Failed to close PR: ${message}`,
        },
        500,
      );
    }
  },
);

githubPrsOpenRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/integrations/github/prs/merge-simple",
    tags: ["Integrations"],
    summary: "Merge a GitHub pull request using the user's GitHub OAuth token",
    request: {
      body: {
        content: {
          "application/json": {
            schema: MergePullRequestSimpleBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        description: "PR merged successfully",
        content: {
          "application/json": {
            schema: z.object({
              success: z.boolean(),
              message: z.string(),
            }),
          },
        },
      },
      400: { description: "Invalid request" },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      500: { description: "Failed to merge PR" },
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
          success: false,
          message: "GitHub account is not connected",
        },
        401,
      );
    }

    const { accessToken: githubAccessToken } = await githubAccount.getAccessToken();
    if (!githubAccessToken) {
      return c.json(
        {
          success: false,
          message: "GitHub access token unavailable",
        },
        401,
      );
    }

    const body = c.req.valid("json");
    const { teamSlugOrId, owner, repo, number, method } = body;

    await verifyTeamAccess({ req: c.req.raw, teamSlugOrId });

    const octokit = createOctokit(githubAccessToken);

    try {
      await mergePullRequest({
        octokit,
        owner,
        repo,
        number,
        method,
        commitTitle: `Merge pull request #${number}`,
        commitMessage: `Merged via cmux`,
      });

      return c.json({
        success: true,
        message: `PR #${number} merged successfully`,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return c.json(
        {
          success: false,
          message: `Failed to merge PR: ${message}`,
        },
        500,
      );
    }
  },
);

function createOctokit(token: string): Octokit {
  return new Octokit({
    auth: token,
    request: {
      timeout: 30_000,
    },
    throttle: {
      onRateLimit: (
        retryAfter: number,
        options: OctokitThrottleOptions,
        _octokit: Octokit,
        retryCount: number,
      ) => {
        const maxRetries = 2;
        const maxWaitSeconds = 15;
        if (retryCount < maxRetries && retryAfter <= maxWaitSeconds) {
          console.warn(
            `GitHub rate limit on ${options.method} ${options.url}. Retrying after ${retryAfter}s (retry #${retryCount + 1}).`,
          );
          return true;
        }
        return false;
      },
      onSecondaryRateLimit: (
        retryAfter: number,
        options: OctokitThrottleOptions,
        _octokit: Octokit,
        retryCount: number,
      ) => {
        const maxRetries = 2;
        const maxWaitSeconds = 15;
        if (retryCount < maxRetries && retryAfter <= maxWaitSeconds) {
          console.warn(
            `GitHub secondary rate limit on ${options.method} ${options.url}. Retrying after ${retryAfter}s (retry #${retryCount + 1}).`,
          );
          return true;
        }
        return false;
      },
    },
  });
}

async function loadPullRequestDetail({
  octokit,
  repoFullName,
  owner,
  repo,
  branchName,
  number,
}: {
  octokit: Octokit;
  repoFullName: string;
  owner: string;
  repo: string;
  branchName: string;
  number?: number;
}): Promise<GitHubPrDetail | null> {
  if (number) {
    try {
      return await fetchPullRequestDetail({
        octokit,
        owner,
        repo,
        number,
      });
    } catch (error) {
      console.warn(
        `[github-open-pr] Failed to fetch PR detail for ${repoFullName}#${number}: ${String(error)}`,
      );
    }
  }

  try {
    const pr = await fetchPullRequestByHead({
      octokit,
      owner,
      repo,
      headOwner: owner,
      branchName,
    });
    if (!pr) {
      return null;
    }
    return await fetchPullRequestDetail({
      octokit,
      owner,
      repo,
      number: pr.number,
    });
  } catch (error) {
    console.warn(
      `[github-open-pr] Failed to locate PR by branch for ${repoFullName}: ${String(error)}`,
    );
    return null;
  }
}

async function fetchPullRequestByHead({
  octokit,
  owner,
  repo,
  headOwner,
  branchName,
}: {
  octokit: Octokit;
  owner: string;
  repo: string;
  headOwner: string;
  branchName: string;
}): Promise<GitHubPrBasic | null> {
  const head = `${headOwner}:${branchName}`;
  const { data } = await octokit.rest.pulls.list({
    owner,
    repo,
    state: "all",
    head,
    per_page: 10,
  });

  if (!Array.isArray(data) || data.length === 0) {
    return null;
  }

  const pr = data[0];
  return {
    number: pr.number,
    html_url: pr.html_url,
    state: pr.state,
    draft: pr.draft ?? undefined,
  };
}

async function fetchPullRequestDetail({
  octokit,
  owner,
  repo,
  number,
}: {
  octokit: Octokit;
  owner: string;
  repo: string;
  number: number;
}): Promise<GitHubPrDetail> {
  const { data } = await octokit.rest.pulls.get({
    owner,
    repo,
    pull_number: number,
  });
  return {
    number: data.number,
    html_url: data.html_url,
    state: data.state,
    draft: data.draft ?? undefined,
    merged_at: data.merged_at,
    node_id: data.node_id,
  };
}

async function createReadyPullRequest({
  octokit,
  owner,
  repo,
  title,
  head,
  base,
  body,
}: {
  octokit: Octokit;
  owner: string;
  repo: string;
  title: string;
  head: string;
  base: string;
  body: string;
}): Promise<GitHubPrBasic> {
  const { data } = await octokit.rest.pulls.create({
    owner,
    repo,
    title,
    head,
    base,
    body,
    draft: false,
  });
  return {
    number: data.number,
    html_url: data.html_url,
    state: data.state,
    draft: data.draft ?? undefined,
  };
}

async function markPullRequestReady({
  octokit,
  owner,
  repo,
  number,
  nodeId,
}: {
  octokit: Octokit;
  owner: string;
  repo: string;
  number: number;
  nodeId: string;
}): Promise<void> {
  const { data } = await octokit.rest.pulls.get({
    owner,
    repo,
    pull_number: number,
  });

  if (!data.draft) {
    return;
  }

  const mutation = `
    mutation($pullRequestId: ID!) {
      markPullRequestReadyForReview(input: { pullRequestId: $pullRequestId }) {
        pullRequest {
          id
          isDraft
        }
      }
    }
  `;

  await octokit.graphql(mutation, {
    pullRequestId: nodeId || data.node_id,
  });
}

async function reopenPullRequest({
  octokit,
  owner,
  repo,
  number,
}: {
  octokit: Octokit;
  owner: string;
  repo: string;
  number: number;
}): Promise<void> {
  await octokit.rest.pulls.update({
    owner,
    repo,
    pull_number: number,
    state: "open",
  });
}

async function mergePullRequest({
  octokit,
  owner,
  repo,
  number,
  method,
  commitTitle,
  commitMessage,
}: {
  octokit: Octokit;
  owner: string;
  repo: string;
  number: number;
  method: "squash" | "rebase" | "merge";
  commitTitle: string;
  commitMessage: string;
}): Promise<void> {
  await octokit.rest.pulls.merge({
    owner,
    repo,
    pull_number: number,
    merge_method: method,
    commit_title: commitTitle,
    commit_message: commitMessage,
  });
}

async function closePullRequest({
  octokit,
  owner,
  repo,
  number,
}: {
  octokit: Octokit;
  owner: string;
  repo: string;
  number: number;
}): Promise<void> {
  await octokit.rest.pulls.update({
    owner,
    repo,
    pull_number: number,
    state: "closed",
  });
}

async function collectRepoFullNamesForRun({
  convex,
  run,
  task,
  teamSlugOrId,
}: {
  convex: ConvexClient;
  run: TaskRunDoc;
  task: TaskDoc;
  teamSlugOrId: string;
}): Promise<string[]> {
  const repos = new Set<string>();
  const project = task.projectFullName?.trim();
  if (project) {
    repos.add(project);
  }

  const environmentId = run.environmentId;
  if (environmentId) {
    try {
      const environment = await convex.query(api.environments.get, {
        teamSlugOrId,
        id: environmentId,
      });
      environment?.selectedRepos?.forEach((repoName) => {
        const trimmed = typeof repoName === "string" ? repoName.trim() : "";
        if (trimmed) {
          repos.add(trimmed);
        }
      });
    } catch (error) {
      console.error(
        "[github-open-pr] Failed to load environment repos for run",
        error,
      );
    }
  }

  return Array.from(repos);
}

async function persistPullRequestResults({
  convex,
  teamSlugOrId,
  run,
  task,
  repoFullNames,
  results,
}: {
  convex: ConvexClient;
  teamSlugOrId: string;
  run: TaskRunDoc;
  task: TaskDoc;
  repoFullNames: readonly string[];
  results: PullRequestActionResult[];
}): Promise<{
  records: StoredPullRequestInfo[];
  aggregate: AggregatePullRequestSummary;
}> {
  const existing = run.pullRequests ?? [];
  const { records, aggregate } = reconcilePullRequestRecords({
    existing,
    updates: results,
    repoFullNames,
  });

  await convex.mutation(api.taskRuns.updatePullRequestState, {
    teamSlugOrId,
    id: run._id,
    state: aggregate.state,
    isDraft: aggregate.isDraft,
    number: aggregate.number,
    url: aggregate.url,
    pullRequests: records,
  });

  await convex.mutation(api.tasks.updateMergeStatus, {
    teamSlugOrId,
    id: task._id,
    mergeStatus: aggregate.mergeStatus,
  });

  return { records, aggregate };
}

function splitRepoFullName(
  repoFullName: string,
): { owner: string; repo: string } | null {
  const [owner, repo] = repoFullName.split("/");
  if (!owner || !repo) {
    return null;
  }
  return { owner, repo };
}

function toPullRequestActionResult(
  repoFullName: string,
  data: GitHubPrDetail,
): PullRequestActionResult {
  const merged = Boolean(data.merged_at);
  return {
    repoFullName,
    url: data.html_url,
    number: data.number,
    state: mapGitHubStateToRunState({
      state: data.state,
      draft: data.draft,
      merged,
    }),
    isDraft: data.draft,
  };
}

function mapGitHubStateToRunState({
  state,
  draft,
  merged,
}: {
  state?: string;
  draft?: boolean;
  merged?: boolean;
}): RunPullRequestState {
  if (merged) {
    return "merged";
  }
  if (draft) {
    return "draft";
  }
  const normalized = (state ?? "").toLowerCase();
  if (normalized === "open") {
    return "open";
  }
  if (normalized === "closed") {
    return "closed";
  }
  if (!normalized) {
    return "none";
  }
  return "unknown";
}

function emptyAggregate(): AggregatePullRequestSummary {
  return {
    state: "none",
    isDraft: false,
    mergeStatus: "none",
  };
}
