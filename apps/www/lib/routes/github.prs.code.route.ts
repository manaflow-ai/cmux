import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "octokit";
import { getConvex } from "../utils/get-convex";
import { githubPrivateKey } from "../utils/githubPrivateKey";

export const githubPrsCodeRouter = new OpenAPIHono();

const Query = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    owner: z.string().min(1).openapi({ description: "GitHub owner/org" }),
    repo: z.string().min(1).openapi({ description: "GitHub repo name" }),
    number: z.coerce.number().min(1).openapi({ description: "PR number" }),
    includeContents: z.coerce
      .boolean()
      .optional()
      .default(false)
      .openapi({ description: "If true, include head file contents (base64)" }),
    includePatch: z.coerce
      .boolean()
      .optional()
      .default(true)
      .openapi({ description: "If true, include unified diff patch hunks" }),
    maxFileBytes: z.coerce
      .number()
      .min(1)
      .max(5_000_000)
      .optional()
      .default(1_000_000)
      .openapi({
        description:
          "Skip fetching contents when file size exceeds this (default 1MB)",
      }),
    maxPages: z.coerce
      .number()
      .min(1)
      .max(50)
      .optional()
      .default(10)
      .openapi({
        description: "Paginate PR files up to this many pages (default 10)",
      }),
  })
  .openapi("GithubPrsCodeQuery");

const FileEntry = z
  .object({
    filename: z.string(),
    status: z.string(),
    sha: z.string().optional(),
    additions: z.number().optional(),
    deletions: z.number().optional(),
    changes: z.number().optional(),
    previous_filename: z.string().optional(),
    patch: z.string().optional(),
    size: z.number().optional(),
    contents: z
      .object({
        encoding: z.literal("base64"),
        content: z.string(),
      })
      .optional(),
    truncated: z.boolean().optional(),
    baseContents: z
      .object({
        encoding: z.literal("base64"),
        content: z.string(),
      })
      .optional(),
    truncatedBase: z.boolean().optional(),
    sizeBase: z.number().optional(),
    html_url: z.string().optional(),
    raw_url: z.string().optional(),
    blob_url: z.string().optional(),
  })
  .openapi("GithubPrFile");

const CodeResponse = z
  .object({
    repoFullName: z.string(),
    number: z.number(),
    head: z.object({ ref: z.string().optional(), sha: z.string().optional() }),
    base: z.object({ ref: z.string().optional(), sha: z.string().optional() }),
    files: z.array(FileEntry),
  })
  .openapi("GithubPrCodeResponse");

githubPrsCodeRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/integrations/github/prs/code",
    tags: ["Integrations"],
    summary: "Fetch PR files, patches, and optional head contents",
    request: { query: Query },
    responses: {
      200: {
        description: "OK",
        content: { "application/json": { schema: CodeResponse } },
      },
      401: { description: "Unauthorized" },
      404: { description: "Not found" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);

    const {
      team,
      owner,
      repo,
      number,
      includeContents = false,
      includePatch = true,
      maxFileBytes = 1_000_000,
      maxPages = 10,
    } = c.req.valid("query");

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
      (co) =>
        (co.isActive ?? true) &&
        (co.accountLogin ?? "").toLowerCase() === owner.toLowerCase()
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

    // Fetch PR to get head/base
    const prRes = await octokit.request(
      "GET /repos/{owner}/{repo}/pulls/{pull_number}",
      { owner, repo, pull_number: number }
    );
    const pr = prRes.data;
    const headSha = pr.head.sha;
    const baseSha = pr.base.sha;

    // Fetch PR files with pagination
    type PrFile = {
      filename: string;
      status: string;
      sha?: string;
      additions?: number;
      deletions?: number;
      changes?: number;
      previous_filename?: string;
      patch?: string;
      raw_url?: string;
      blob_url?: string;
      contents_url?: string;
      html_url?: string;
    };
    const files: PrFile[] = [];
    for (let page = 1; page <= maxPages; page++) {
      const filesRes = await octokit.request(
        "GET /repos/{owner}/{repo}/pulls/{pull_number}/files",
        {
          owner,
          repo,
          pull_number: number,
          per_page: 100,
          page,
        }
      );
      const chunk = filesRes.data || [];
      files.push(...chunk);
      if (chunk.length < 100) break;
    }

    // Optionally fetch head contents for each file (skip removed, big files)
    const outFiles: Array<z.infer<typeof FileEntry>> = [];
    for (const f of files) {
      const entry: z.infer<typeof FileEntry> = {
        filename: f.filename,
        status: f.status,
        sha: f.sha,
        additions: f.additions,
        deletions: f.deletions,
        changes: f.changes,
        previous_filename: f.previous_filename,
        patch: includePatch ? f.patch : undefined,
        html_url: f.html_url,
        raw_url: f.raw_url,
        blob_url: f.blob_url,
      };
      if (includeContents && headSha && f.status !== "removed") {
        try {
          const contentsRes = await octokit.request(
            "GET /repos/{owner}/{repo}/contents/{path}",
            {
              owner,
              repo,
              path: f.filename,
              ref: headSha,
            }
          );
          const contentObj = contentsRes.data as unknown as {
            size?: number;
            encoding?: string;
            content?: string;
            type?: string;
          };
          const typ = contentObj.type;
          const size =
            typeof contentObj.size === "number" ? contentObj.size : undefined;
          if (typ === "file" && (size === undefined || size <= maxFileBytes)) {
            if (
              contentObj.encoding === "base64" &&
              typeof contentObj.content === "string"
            ) {
              entry.size = size;
              entry.contents = {
                encoding: "base64",
                content: contentObj.content,
              };
            } else {
              entry.truncated = true; // unexpected format
              entry.size = size;
            }
          } else {
            entry.truncated = true;
            if (size !== undefined) entry.size = size;
          }
        } catch (_e) {
          entry.truncated = true;
        }
      }

      if (includeContents && baseSha && f.status !== "added") {
        try {
          const path = f.previous_filename ?? f.filename;
          const baseRes = await octokit.request(
            "GET /repos/{owner}/{repo}/contents/{path}",
            {
              owner,
              repo,
              path,
              ref: baseSha,
            }
          );
          const baseObj = baseRes.data as unknown as {
            size?: number;
            encoding?: string;
            content?: string;
            type?: string;
          };
          const typ = baseObj.type;
          const size =
            typeof baseObj.size === "number" ? baseObj.size : undefined;
          if (typ === "file" && (size === undefined || size <= maxFileBytes)) {
            if (
              baseObj.encoding === "base64" &&
              typeof baseObj.content === "string"
            ) {
              entry.sizeBase = size;
              entry.baseContents = {
                encoding: "base64",
                content: baseObj.content,
              };
            } else {
              entry.truncatedBase = true;
              entry.sizeBase = size;
            }
          } else {
            entry.truncatedBase = true;
            if (size !== undefined) entry.sizeBase = size;
          }
        } catch (_e) {
          entry.truncatedBase = true;
        }
      }
      outFiles.push(entry);
    }

    return c.json({
      repoFullName: `${owner}/${repo}`,
      number,
      head: { ref: pr.head?.ref, sha: pr.head?.sha },
      base: { ref: pr.base?.ref, sha: pr.base?.sha },
      files: outFiles,
    });
  }
);
