import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "octokit";
import { getConvex } from "../utils/get-convex";
import { githubPrivateKey } from "../utils/githubPrivateKey";

export const githubPrsBackfillRepoRouter = new OpenAPIHono();

const Body = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    repoFullName: z
      .string()
      .regex(/^[^/]+\/.+$/)
      .openapi({ description: "owner/repo" }),
    state: z
      .enum(["open", "closed", "all"]) 
      .optional()
      .default("all")
      .openapi({ description: "PR state to backfill (default all)" }),
    maxPages: z.coerce
      .number()
      .min(1)
      .max(100)
      .optional()
      .default(50)
      .openapi({ description: "Safety cap on number of pages (default 50)" }),
  })
  .openapi("GithubPrsBackfillRepoBody");

githubPrsBackfillRepoRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/integrations/github/prs/backfill-repo",
    tags: ["Integrations"],
    summary: "Backfill all PRs for a repo and persist to Convex",
    request: {
      body: {
        content: {
          "application/json": { schema: Body },
        },
        required: true,
      },
    },
    responses: {
      200: {
        description: "OK",
      },
      400: { description: "Bad request" },
      401: { description: "Unauthorized" },
      404: { description: "Not found" },
      501: { description: "Not configured" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { team, repoFullName, state = "all", maxPages = 50 } = c.req.valid("json");
    const [owner, repo] = repoFullName.split("/", 2);
    if (!owner || !repo) return c.text("Bad repo name", 400);

    const convex = getConvex({ accessToken });
    const connections = await convex.query(api.github.listProviderConnections, {
      teamSlugOrId: team,
    });
    type Conn = {
      installationId: number;
      accountLogin?: string | null;
      isActive?: boolean | null;
    };
    const target = (connections as Conn[]).find(
      (co) => (co.isActive ?? true) && (co.accountLogin ?? "").toLowerCase() === owner.toLowerCase()
    );
    if (!target) return c.text("Installation not found for owner", 404);

    const octokit = new Octokit({
      authStrategy: createAppAuth,
      auth: {
        appId: env.CMUX_GITHUB_APP_ID,
        privateKey: githubPrivateKey,
        installationId: target.installationId,
      },
    });

    type Pull = {
      id: number;
      number: number;
      title: string;
      state: string;
      merged?: boolean;
      draft?: boolean;
      user?: { login?: string; id?: number } | null;
      html_url?: string;
      base?: { ref?: string; sha?: string; repo?: { id?: number } };
      head?: { ref?: string; sha?: string };
      created_at?: string;
      updated_at?: string;
      closed_at?: string | null;
      merged_at?: string | null;
      comments?: number;
      review_comments?: number;
      commits?: number;
      additions?: number;
      deletions?: number;
      changed_files?: number;
    };

    const ts = (s?: string | null) => (s ? Date.parse(s) : undefined);

    let page = 1;
    let total = 0;
    const per_page = 100 as const;
    for (; page <= maxPages; page++) {
      const res = await octokit.request("GET /repos/{owner}/{repo}/pulls", {
        owner,
        repo,
        state,
        per_page,
        page,
        sort: "updated",
        direction: "desc",
      });
      const items = (res.data as unknown as Pull[]) || [];
      if (items.length === 0) break;
      for (const pr of items) {
        await convex.mutation(api.github_prs.upsertFromServer, {
          teamSlugOrId: team,
          installationId: target.installationId,
          repoFullName: `${owner}/${repo}`,
          number: pr.number,
          record: {
            providerPrId: pr.id,
            repositoryId: pr.base?.repo?.id,
            title: pr.title,
            state: pr.state === "closed" ? "closed" : "open",
            merged: !!pr.merged,
            draft: !!pr.draft,
            authorLogin: pr.user?.login ?? undefined,
            authorId: pr.user?.id ?? undefined,
            htmlUrl: pr.html_url ?? undefined,
            baseRef: pr.base?.ref ?? undefined,
            headRef: pr.head?.ref ?? undefined,
            baseSha: pr.base?.sha ?? undefined,
            headSha: pr.head?.sha ?? undefined,
            createdAt: ts(pr.created_at),
            updatedAt: ts(pr.updated_at),
            closedAt: ts(pr.closed_at ?? undefined),
            mergedAt: ts(pr.merged_at ?? undefined),
            commentsCount: pr.comments,
            reviewCommentsCount: pr.review_comments,
            commitsCount: pr.commits,
            additions: pr.additions,
            deletions: pr.deletions,
            changedFiles: pr.changed_files,
          },
        });
        total += 1;
      }
      if (items.length < per_page) break;
    }

    return c.json({ ok: true, count: total, pages: page - 1 });
  }
);

