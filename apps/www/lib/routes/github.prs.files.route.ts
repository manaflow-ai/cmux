import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "octokit";
import { getConvex } from "../utils/get-convex";
import { githubPrivateKey } from "../utils/githubPrivateKey";

export const githubPrsFilesRouter = new OpenAPIHono();

const Query = z
  .object({
    team: z.string().min(1),
    owner: z.string().min(1),
    repo: z.string().min(1),
    number: z.coerce.number().min(1),
    maxPages: z.coerce.number().min(1).max(50).optional().default(10),
  })
  .openapi("GithubPrsFilesQuery");

const FilesResponse = z
  .object({
    repoFullName: z.string(),
    number: z.number(),
    head: z.object({ ref: z.string().optional(), sha: z.string().optional() }),
    base: z.object({ ref: z.string().optional(), sha: z.string().optional() }),
    files: z.array(
      z.object({
        filename: z.string(),
        previous_filename: z.string().optional(),
        status: z.string(),
        additions: z.number().optional(),
        deletions: z.number().optional(),
        changes: z.number().optional(),
        patch: z.string().optional(),
      })
    ),
  })
  .openapi("GithubPrsFilesResponse");

githubPrsFilesRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/integrations/github/prs/files",
    tags: ["Integrations"],
    summary: "List PR files without contents (fast)",
    request: { query: Query },
    responses: {
      200: { description: "OK", content: { "application/json": { schema: FilesResponse } } },
      401: { description: "Unauthorized" },
      404: { description: "Not found" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);
    const { team, owner, repo, number, maxPages = 10 } = c.req.valid("query");

    const convex = getConvex({ accessToken });
    const connections = await convex.query(api.github.listProviderConnections, { teamSlugOrId: team });
    type Conn = { installationId: number; accountLogin?: string | null; isActive?: boolean | null };
    const target = (connections as Conn[]).find(
      (co) => (co.isActive ?? true) && (co.accountLogin ?? "").toLowerCase() === owner.toLowerCase()
    );
    if (!target) return c.text("Installation not found for owner", 404);

    const octokit = new Octokit({
      authStrategy: createAppAuth,
      auth: { appId: env.CMUX_GITHUB_APP_ID, privateKey: githubPrivateKey, installationId: target.installationId },
    });

    const prRes = await octokit.request("GET /repos/{owner}/{repo}/pulls/{pull_number}", {
      owner,
      repo,
      pull_number: number,
    });
    const pr = prRes.data as unknown as { head?: { ref?: string; sha?: string }; base?: { ref?: string; sha?: string } };

    const files: Array<{
      filename: string;
      previous_filename?: string;
      status: string;
      additions?: number;
      deletions?: number;
      changes?: number;
      patch?: string;
    }> = [];
    for (let page = 1; page <= maxPages; page++) {
      const filesRes = await octokit.request(
        "GET /repos/{owner}/{repo}/pulls/{pull_number}/files",
        { owner, repo, pull_number: number, per_page: 100, page }
      );
      const chunk = (filesRes.data as unknown as typeof files) || [];
      files.push(...chunk);
      if (chunk.length < 100) break;
    }

    return c.json({
      repoFullName: `${owner}/${repo}`,
      number,
      head: { ref: pr.head?.ref, sha: pr.head?.sha },
      base: { ref: pr.base?.ref, sha: pr.base?.sha },
      files: files.map((f) => ({
        filename: f.filename,
        previous_filename: f.previous_filename,
        status: f.status,
        additions: f.additions,
        deletions: f.deletions,
        changes: f.changes,
        patch: f.patch,
      })),
    });
  }
);

