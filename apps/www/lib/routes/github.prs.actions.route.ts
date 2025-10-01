import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "octokit";
import { getConvex } from "../utils/get-convex";
import { githubPrivateKey } from "../utils/githubPrivateKey";

export const githubPrsActionsRouter = new OpenAPIHono();

const MergePRBody = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    owner: z.string().min(1).openapi({ description: "GitHub owner/org" }),
    repo: z.string().min(1).openapi({ description: "GitHub repo name" }),
    number: z.coerce.number().min(1).openapi({ description: "PR number" }),
    merge_method: z
      .enum(["merge", "squash", "rebase"])
      .optional()
      .default("merge")
      .openapi({ description: "Merge method (default merge)" }),
    commit_title: z
      .string()
      .optional()
      .openapi({ description: "Custom commit title" }),
    commit_message: z
      .string()
      .optional()
      .openapi({ description: "Custom commit message" }),
  })
  .openapi("MergePRBody");

const ClosePRBody = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
    owner: z.string().min(1).openapi({ description: "GitHub owner/org" }),
    repo: z.string().min(1).openapi({ description: "GitHub repo name" }),
    number: z.coerce.number().min(1).openapi({ description: "PR number" }),
  })
  .openapi("ClosePRBody");

const SuccessResponse = z
  .object({
    success: z.boolean(),
    message: z.string(),
  })
  .openapi("PRActionSuccessResponse");

const ErrorResponse = z
  .object({
    success: z.boolean(),
    error: z.string(),
  })
  .openapi("PRActionErrorResponse");

// Merge PR endpoint
githubPrsActionsRouter.openapi(
  createRoute({
    method: "put" as const,
    path: "/integrations/github/prs/merge",
    tags: ["Integrations"],
    summary: "Merge a pull request",
    request: {
      body: {
        content: {
          "application/json": {
            schema: MergePRBody,
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
            schema: SuccessResponse,
          },
        },
      },
      400: {
        description: "Bad request or PR cannot be merged",
        content: {
          "application/json": {
            schema: ErrorResponse,
          },
        },
      },
      401: { description: "Unauthorized" },
      404: { description: "PR or installation not found" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.json({ success: false, error: "Unauthorized" }, 401);

    const { team, owner, repo, number, merge_method = "merge", commit_title, commit_message } =
      c.req.valid("json");

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

    if (!target) {
      return c.json(
        { success: false, error: "Installation not found for owner" },
        404
      );
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
      await octokit.request("PUT /repos/{owner}/{repo}/pulls/{pull_number}/merge", {
        owner,
        repo,
        pull_number: number,
        merge_method,
        ...(commit_title && { commit_title }),
        ...(commit_message && { commit_message }),
      });

      return c.json({
        success: true,
        message: "Pull request merged successfully",
      });
    } catch (err) {
      console.error("Failed to merge PR:", err);
      const errorMessage = err instanceof Error ? err.message : "Unknown error";
      return c.json(
        { success: false, error: errorMessage },
        400
      );
    }
  }
);

// Close PR endpoint
githubPrsActionsRouter.openapi(
  createRoute({
    method: "patch" as const,
    path: "/integrations/github/prs/close",
    tags: ["Integrations"],
    summary: "Close a pull request",
    request: {
      body: {
        content: {
          "application/json": {
            schema: ClosePRBody,
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
            schema: SuccessResponse,
          },
        },
      },
      400: {
        description: "Bad request",
        content: {
          "application/json": {
            schema: ErrorResponse,
          },
        },
      },
      401: { description: "Unauthorized" },
      404: { description: "PR or installation not found" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.json({ success: false, error: "Unauthorized" }, 401);

    const { team, owner, repo, number } = c.req.valid("json");

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

    if (!target) {
      return c.json(
        { success: false, error: "Installation not found for owner" },
        404
      );
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
      await octokit.request("PATCH /repos/{owner}/{repo}/pulls/{pull_number}", {
        owner,
        repo,
        pull_number: number,
        state: "closed",
      });

      return c.json({
        success: true,
        message: "Pull request closed successfully",
      });
    } catch (err) {
      console.error("Failed to close PR:", err);
      const errorMessage = err instanceof Error ? err.message : "Unknown error";
      return c.json(
        { success: false, error: errorMessage },
        400
      );
    }
  }
);
