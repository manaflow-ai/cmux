import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "octokit";
import { getConvex } from "../utils/get-convex";
import { githubPrivateKey } from "../utils/githubPrivateKey";

export const githubPrsFileContentsRouter = new OpenAPIHono();

const Query = z
  .object({
    team: z.string().min(1),
    owner: z.string().min(1),
    repo: z.string().min(1),
    number: z.coerce.number().min(1),
    path: z.string().min(1),
    previous_filename: z.string().optional(),
    which: z.enum(["both", "head", "base"]).optional().default("both"),
    maxFileBytes: z.coerce.number().min(1).max(5_000_000).optional().default(1_000_000),
  })
  .openapi("GithubPrsFileContentsQuery");

const Resp = z
  .object({
    path: z.string(),
    head: z
      .object({ encoding: z.literal("base64"), content: z.string(), size: z.number().optional() })
      .optional(),
    base: z
      .object({ encoding: z.literal("base64"), content: z.string(), size: z.number().optional() })
      .optional(),
    truncatedHead: z.boolean().optional(),
    truncatedBase: z.boolean().optional(),
  })
  .openapi("GithubPrsFileContentsResponse");

githubPrsFileContentsRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/integrations/github/prs/file-contents",
    tags: ["Integrations"],
    summary: "Fetch base/head contents for a single file in a PR",
    request: { query: Query },
    responses: {
      200: { description: "OK", content: { "application/json": { schema: Resp } } },
      401: { description: "Unauthorized" },
      404: { description: "Not found" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);
    const { team, owner, repo, number, path, previous_filename, which = "both", maxFileBytes } =
      c.req.valid("query");

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
    const pr = prRes.data as unknown as { head?: { sha?: string }; base?: { sha?: string } };
    const headSha = pr.head?.sha;
    const baseSha = pr.base?.sha;

    const out: z.infer<typeof Resp> = { path };

    const fetchContent = async (
      ref: string | undefined,
      p: string
    ): Promise<{ encoding: "base64"; content: string; size?: number } | { truncated: true; size?: number } | null> => {
      if (!ref) return null;
      try {
        const res = await octokit.request("GET /repos/{owner}/{repo}/contents/{path}", {
          owner,
          repo,
          path: p,
          ref,
        });
        const obj = res.data as unknown as { size?: number; encoding?: string; content?: string; type?: string };
        const size = typeof obj.size === "number" ? obj.size : undefined;
        if (obj.type === "file" && (size === undefined || size <= maxFileBytes)) {
          if (obj.encoding === "base64" && typeof obj.content === "string") {
            return { encoding: "base64", content: obj.content, size };
          }
          return { truncated: true, size } as const;
        }
        return { truncated: true, size } as const;
      } catch {
        return { truncated: true } as const;
      }
    };

    if (which === "both" || which === "head") {
      const head = await fetchContent(headSha, path);
      if (head && "encoding" in head) out.head = head;
      else if (head && "truncated" in head) out.truncatedHead = true;
    }
    if (which === "both" || which === "base") {
      const p = previous_filename ?? path;
      const base = await fetchContent(baseSha, p);
      if (base && "encoding" in base) out.base = base;
      else if (base && "truncated" in base) out.truncatedBase = true;
    }

    return c.json(out);
  }
);
