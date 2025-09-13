import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "octokit";
import { getConvex } from "../utils/get-convex";
import { githubPrivateKey } from "../utils/githubPrivateKey";

export const githubPrsPatchRouter = new OpenAPIHono();

const Query = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    owner: z.string().min(1).openapi({ description: "GitHub owner/org" }),
    repo: z.string().min(1).openapi({ description: "GitHub repo name" }),
    number: z.coerce.number().min(1).openapi({ description: "PR number" }),
    format: z
      .enum(["patch", "diff"]).optional().default("patch")
      .openapi({ description: "Return .patch or .diff format (default patch)" }),
  })
  .openapi("GithubPrsPatchQuery");

githubPrsPatchRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/integrations/github/prs/raw",
    tags: ["Integrations"],
    summary: "Fetch raw .patch or .diff for a PR (private repos supported)",
    request: { query: Query },
    responses: {
      200: {
        description: "OK",
        content: { "text/plain": { schema: z.string() } },
      },
      401: { description: "Unauthorized" },
      404: { description: "Not found" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const { team, owner, repo, number, format = "patch" } = c.req.valid("query");
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

    const accept = format === "diff" ? "application/vnd.github.v3.diff" : "application/vnd.github.v3.patch";
    const res = await octokit.request(
      "GET /repos/{owner}/{repo}/pulls/{pull_number}",
      {
        owner,
        repo,
        pull_number: number,
        headers: { accept },
      }
    );
    const text = String(res.data as unknown as string);
    return new Response(text, {
      status: 200,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  }
);

