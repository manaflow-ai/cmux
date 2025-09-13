import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "octokit";
import { getConvex } from "../utils/get-convex";
import { githubPrivateKey } from "../utils/githubPrivateKey";

export const githubPrsFileContentsBatchRouter = new OpenAPIHono();

const FileReq = z.object({ path: z.string(), previous_filename: z.string().optional() });

const Body = z
  .object({
    team: z.string().min(1),
    owner: z.string().min(1),
    repo: z.string().min(1),
    number: z.coerce.number().min(1),
    files: z.array(FileReq).min(1),
    which: z.enum(["both", "head", "base"]).optional().default("both"),
    maxFileBytes: z.coerce.number().min(1).max(5_000_000).optional().default(1_000_000),
  })
  .openapi("GithubPrsFileContentsBatchBody");

const FileResp = z.object({
  path: z.string(),
  head: z
    .object({ encoding: z.literal("base64"), content: z.string(), size: z.number().optional() })
    .optional(),
  base: z
    .object({ encoding: z.literal("base64"), content: z.string(), size: z.number().optional() })
    .optional(),
  truncatedHead: z.boolean().optional(),
  truncatedBase: z.boolean().optional(),
  headSize: z.number().optional(),
  baseSize: z.number().optional(),
});

const Resp = z
  .object({
    repoFullName: z.string(),
    number: z.number(),
    head: z.object({ ref: z.string().optional(), sha: z.string().optional() }),
    base: z.object({ ref: z.string().optional(), sha: z.string().optional() }),
    results: z.array(FileResp),
  })
  .openapi("GithubPrsFileContentsBatchResponse");

githubPrsFileContentsBatchRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/integrations/github/prs/file-contents/batch",
    tags: ["Integrations"],
    summary: "Batch fetch base/head contents for many files in a PR using git blobs",
    request: {
      body: {
        content: { "application/json": { schema: Body } },
        required: true,
      },
    },
    responses: {
      200: { description: "OK", content: { "application/json": { schema: Resp } } },
      401: { description: "Unauthorized" },
      404: { description: "Not found" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);
    const { team, owner, repo, number, files, which = "both", maxFileBytes } = c.req.valid("json");

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
    const headSha = pr.head?.sha;
    const baseSha = pr.base?.sha;

    const headTreeMap = new Map<string, { sha: string; size?: number }>();
    const baseTreeMap = new Map<string, { sha: string; size?: number }>();

    async function fetchTree(sha: string | undefined, map: Map<string, { sha: string; size?: number }>) {
      if (!sha) return;
      try {
        const treeRes = await octokit.request(
          "GET /repos/{owner}/{repo}/git/trees/{tree_sha}?recursive=1",
          { owner, repo, tree_sha: sha }
        );
        const entries = (treeRes.data as unknown as { tree?: Array<{ path?: string; type?: string; sha?: string; size?: number }> }).tree || [];
        for (const e of entries) {
          if (e.type === "blob" && e.path && e.sha) {
            map.set(e.path, { sha: e.sha, size: e.size });
          }
        }
      } catch {
        // ignore
      }
    }

    await Promise.all([fetchTree(headSha, headTreeMap), fetchTree(baseSha, baseTreeMap)]);

    async function fetchBlob(sha: string): Promise<{ encoding: "base64"; content: string; size?: number } | null> {
      try {
        const res = await octokit.request("GET /repos/{owner}/{repo}/git/blobs/{file_sha}", {
          owner,
          repo,
          file_sha: sha,
        });
        const obj = res.data as unknown as { encoding?: string; content?: string; size?: number };
        if (obj.encoding === "base64" && typeof obj.content === "string") {
          return { encoding: "base64", content: obj.content, size: obj.size };
        }
        return null;
      } catch {
        return null;
      }
    }

    const results: Array<z.infer<typeof FileResp>> = [];
    const maxConcurrency = 6;
    let inFlight = 0;
    let i = 0;
    await new Promise<void>((resolve) => {
      const runNext = () => {
        while (inFlight < maxConcurrency && i < files.length) {
          const file = files[i++];
          inFlight++;
          (async () => {
            const resp: z.infer<typeof FileResp> = { path: file.path };
            if (which === "both" || which === "head") {
              const h = headTreeMap.get(file.path);
              if (h) {
                if (h.size === undefined || h.size <= maxFileBytes) {
                  const blob = await fetchBlob(h.sha);
                  if (blob) resp.head = blob;
                  else resp.truncatedHead = true;
                } else {
                  resp.truncatedHead = true;
                  resp.headSize = h.size;
                }
              } else {
                resp.truncatedHead = true;
              }
            }
            if (which === "both" || which === "base") {
              const basePath = file.previous_filename ?? file.path;
              const b = baseTreeMap.get(basePath);
              if (b) {
                if (b.size === undefined || b.size <= maxFileBytes) {
                  const blob = await fetchBlob(b.sha);
                  if (blob) resp.base = blob;
                  else resp.truncatedBase = true;
                } else {
                  resp.truncatedBase = true;
                  resp.baseSize = b.size;
                }
              } else {
                resp.truncatedBase = true;
              }
            }
            results.push(resp);
          })()
            .catch(() => {
              // ignore
            })
            .finally(() => {
              inFlight--;
              if (results.length === files.length) resolve();
              else runNext();
            });
        }
      };
      runNext();
    });

    return c.json({
      repoFullName: `${owner}/${repo}`,
      number,
      head: { ref: pr.head?.ref, sha: pr.head?.sha },
      base: { ref: pr.base?.ref, sha: pr.base?.sha },
      results,
    });
  }
);
