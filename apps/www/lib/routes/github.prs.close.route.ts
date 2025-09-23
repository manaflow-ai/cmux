import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "octokit";
import { getConvex } from "../utils/get-convex";
import { githubPrivateKey } from "../utils/githubPrivateKey";

export const githubPrsCloseRouter = new OpenAPIHono();

const Body = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    owner: z.string().min(1).openapi({ description: "GitHub owner/org" }),
    repo: z.string().min(1).openapi({ description: "GitHub repo name" }),
    number: z.coerce.number().min(1).openapi({ description: "PR number" }),
  })
  .openapi("GithubPrsCloseBody");

const Response = z
  .object({
    ok: z.literal(true),
    number: z.number(),
    state: z.enum(["open", "closed"]),
    merged: z.boolean().optional(),
    html_url: z.string().url().optional(),
  })
  .openapi("GithubPrsCloseResponse");

githubPrsCloseRouter.openapi(
  createRoute({
    method: "post",
    path: "/integrations/github/prs/close",
    tags: ["Integrations"],
    summary: "Close a pull request via GitHub API and sync Convex",
    request: {
      body: {
        content: {
          "application/json": {
            schema: Body,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        description: "Closed PR",
        content: { "application/json": { schema: Response } },
      },
      401: { description: "Unauthorized" },
      404: { description: "Installation not found for owner" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { team, owner, repo, number } = c.req.valid("json");

    // Find GitHub installation for the owner within this team
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

    // Close the PR
    const res = await octokit.request(
      "PATCH /repos/{owner}/{repo}/pulls/{pull_number}",
      {
        owner,
        repo,
        pull_number: number,
        state: "closed",
      }
    );

    const pr = res.data as unknown as Record<string, unknown>;
    // Map fields to Convex record shape
    const mapStr = (v: unknown) => (typeof v === "string" ? v : undefined);
    const mapNum = (v: unknown) => (typeof v === "number" ? v : undefined);
    const bool = (v: unknown) => Boolean(v);
    const ts = (s: unknown) => {
      if (typeof s !== "string") return undefined;
      const n = Date.parse(s);
      return Number.isFinite(n) ? n : undefined;
    };

    const base = (pr?.base ?? {}) as Record<string, unknown>;
    const head = (pr?.head ?? {}) as Record<string, unknown>;
    const baseRepo = (base?.repo ?? {}) as Record<string, unknown>;
    const user = (pr?.user ?? {}) as Record<string, unknown>;

    const record = {
      providerPrId: mapNum(pr.id),
      repositoryId: mapNum(baseRepo.id),
      title: mapStr(pr.title) ?? "",
      state: mapStr(pr.state) === "closed" ? ("closed" as const) : ("open" as const),
      merged: bool(pr.merged),
      draft: bool(pr.draft),
      authorLogin: mapStr(user.login),
      authorId: mapNum(user.id),
      htmlUrl: mapStr(pr.html_url),
      baseRef: mapStr(base.ref),
      headRef: mapStr(head.ref),
      baseSha: mapStr(base.sha),
      headSha: mapStr(head.sha),
      createdAt: ts(pr.created_at),
      updatedAt: ts(pr.updated_at),
      closedAt: ts(pr.closed_at),
      mergedAt: ts(pr.merged_at),
      commentsCount: mapNum(pr.comments),
      reviewCommentsCount: mapNum(pr.review_comments),
      commitsCount: mapNum(pr.commits),
      additions: mapNum(pr.additions),
      deletions: mapNum(pr.deletions),
      changedFiles: mapNum(pr.changed_files),
    };

    // Persist to Convex so UI updates immediately
    const repoFullName = `${owner}/${repo}`;
    await convex.mutation(api.github_prs.upsertFromServer, {
      teamSlugOrId: team,
      installationId: target.installationId,
      repoFullName,
      number,
      record,
    });

    return c.json({
      ok: true as const,
      number,
      state: record.state,
      merged: record.merged,
      html_url: record.htmlUrl,
    });
  }
);

