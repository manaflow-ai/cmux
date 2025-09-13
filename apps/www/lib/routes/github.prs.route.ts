import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "octokit";
import { getConvex } from "../utils/get-convex";
import { githubPrivateKey } from "../utils/githubPrivateKey";

export const githubPrsRouter = new OpenAPIHono();

const Query = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    installationId: z.coerce
      .number()
      .optional()
      .openapi({ description: "GitHub App installation ID to query" }),
    q: z
      .string()
      .trim()
      .min(1)
      .optional()
      .openapi({ description: "Optional search term to filter by title or author" }),
    state: z
      .enum(["open", "closed", "all"])
      .optional()
      .default("open")
      .openapi({ description: "Filter PRs by state (default open)" }),
    page: z.coerce
      .number()
      .min(1)
      .default(1)
      .optional()
      .openapi({ description: "1-based page index (default 1)" }),
    per_page: z.coerce
      .number()
      .min(1)
      .max(100)
      .default(20)
      .optional()
      .openapi({ description: "Results per page (default 20, max 100)" }),
  })
  .openapi("GithubPrsQuery");

const PullRequestItem = z
  .object({
    id: z.number(),
    number: z.number(),
    title: z.string(),
    state: z.enum(["open", "closed"]),
    user: z
      .object({
        login: z.string(),
        id: z.number(),
        avatar_url: z.string().url().optional(),
      })
      .optional(),
    repository_full_name: z.string(),
    html_url: z.string().url(),
    created_at: z.string().optional(),
    updated_at: z.string().optional(),
    comments: z.number().optional(),
  })
  .openapi("GithubPullRequestItem");

const PullRequestsResponse = z
  .object({
    total_count: z.number(),
    pullRequests: z.array(PullRequestItem),
  })
  .openapi("GithubPullRequestsResponse");

githubPrsRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/integrations/github/prs",
    tags: ["Integrations"],
    summary: "List pull requests across a GitHub App installation for a team",
    request: { query: Query },
    responses: {
      200: {
        description: "OK",
        content: {
          "application/json": {
            schema: PullRequestsResponse,
          },
        },
      },
      401: { description: "Unauthorized" },
      400: { description: "Bad request" },
      501: { description: "Not configured" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { team, installationId, q, state = "open", page = 1, per_page = 20 } =
      c.req.valid("query");

    // Fetch provider connections for this team using Convex (enforces membership)
    const convex = getConvex({ accessToken });
    const connections = await convex.query(api.github.listProviderConnections, {
      teamSlugOrId: team,
    });

    // Determine which installation to query
    type Conn = {
      installationId: number;
      isActive?: boolean | null;
      accountLogin?: string | null;
      accountType?: "Organization" | "User" | null;
    };
    const target = (connections as Conn[]).find(
      (co: Conn) => co.isActive !== false && (!installationId || co.installationId === installationId)
    );

    if (!target) {
      return c.json({ total_count: 0, pullRequests: [] });
    }

    const octokit = new Octokit({
      authStrategy: createAppAuth,
      auth: {
        appId: env.CMUX_GITHUB_APP_ID,
        privateKey: githubPrivateKey,
        installationId: target.installationId,
      },
    });

    try {
      if (!target.accountLogin) {
        throw new Error(
          `No account login for installation ${target.installationId}`
        );
      }
      const ownerQualifier =
        target.accountType === "Organization"
          ? `org:${target.accountLogin}`
          : `user:${target.accountLogin}`;

      const qualifiers = ["is:pr", ownerQualifier];
      if (state === "open") qualifiers.push("is:open");
      else if (state === "closed") qualifiers.push("is:closed");

      if (q && q.trim().length > 0) {
        // Let GitHub search handle free text (title/body/author)
        qualifiers.push(q.trim());
      }

      const searchQuery = qualifiers.join(" ");
      const res = await octokit.request("GET /search/issues", {
        q: searchQuery,
        sort: "updated",
        order: "desc",
        per_page,
        page,
      });

      type SearchIssueItem = {
        id: number;
        number: number;
        title: string;
        state: "open" | "closed" | string;
        html_url: string;
        repository_url?: string;
        pull_request?: unknown;
        created_at?: string;
        updated_at?: string;
        comments?: number;
        user?: {
          login: string;
          id: number;
          avatar_url?: string;
        };
      };

      const isSearchIssueItem = (v: unknown): v is SearchIssueItem => {
        if (!v || typeof v !== "object") return false;
        const o = v as Record<string, unknown>;
        return (
          typeof o.id === "number" &&
          typeof o.number === "number" &&
          typeof o.title === "string" &&
          typeof o.state === "string" &&
          typeof o.html_url === "string"
        );
      };

      const rawItems: unknown[] = Array.isArray(res.data.items)
        ? (res.data.items as unknown[])
        : [];
      const items = rawItems
        .filter((it: unknown): it is SearchIssueItem =>
          isSearchIssueItem(it) && !!(it as SearchIssueItem).pull_request
        )
        .map((it) => {
          // repository_url looks like https://api.github.com/repos/{owner}/{repo}
          const repoUrl = it.repository_url || "";
          const parts = repoUrl.split("/");
          const owner = parts[parts.length - 2] || "";
          const repo = parts[parts.length - 1] || "";

          return {
            id: it.id,
            number: it.number,
            title: it.title,
            state: (it.state === "open" || it.state === "closed" ? it.state : "open") as
              | "open"
              | "closed",
            user: it.user
              ? {
                  login: it.user.login,
                  id: it.user.id,
                  avatar_url: it.user.avatar_url,
                }
              : undefined,
            repository_full_name: owner && repo ? `${owner}/${repo}` : "",
            html_url: it.html_url,
            created_at: it.created_at,
            updated_at: it.updated_at,
            comments: typeof it.comments === "number" ? it.comments : undefined,
          };
        });

      return c.json({ total_count: typeof res.data.total_count === "number" ? res.data.total_count : 0, pullRequests: items });
    } catch (err) {
      console.error(
        `GitHub PRs fetch failed for installation ${target.installationId}:`,
        err instanceof Error ? err.message : err
      );
      return c.json({ total_count: 0, pullRequests: [] });
    }
  }
);
