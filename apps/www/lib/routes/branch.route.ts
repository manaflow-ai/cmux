import { trackModelUsage } from "@/lib/analytics/events";
import {
  generateBranchNamesFromBase,
  generateNewBranchName,
  generateUniqueBranchNames,
  mergeApiKeysWithEnv,
  toKebabCase,
} from "@/lib/utils/branch-name-generator";
import { getConvex } from "@/lib/utils/get-convex";
import { stackServerAppJs } from "@/lib/utils/stack";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { HTTPException } from "hono/http-exception";

export const branchRouter = new OpenAPIHono();

const GenerateBranchesBody = z
  .object({
    teamSlugOrId: z.string(),
    taskDescription: z.string().optional(),
    prTitle: z.string().optional(),
    count: z.number().int().min(1).max(2000).default(1),
    uniqueId: z
      .string()
      .regex(/^[a-z0-9]{5}$/)
      .optional(),
  })
  .refine(
    (value) => Boolean(value.taskDescription || value.prTitle),
    "Provide either taskDescription or prTitle",
  )
  .openapi("GenerateBranchesBody");

const GenerateBranchesResponse = z
  .object({
    branchNames: z.array(z.string()),
    baseBranchName: z.string(),
    prTitle: z.string().optional(),
    usedFallback: z.boolean(),
    providerName: z.string().nullable(),
  })
  .openapi("GenerateBranchesResponse");

const MODEL_NAME_BY_PROVIDER: Record<string, string> = {
  OpenAI: "gpt-5-nano",
  Gemini: "gemini-2.5-flash",
  Anthropic: "claude-3-5-haiku-20241022",
};

const resolveModelName = (providerName: string | null): string | null => {
  if (!providerName) return null;
  return MODEL_NAME_BY_PROVIDER[providerName] ?? null;
};

branchRouter.openapi(
  createRoute({
    method: "post",
    path: "/branches/generate",
    tags: ["Branches"],
    summary: "Generate git branch names for task runs",
    request: {
      body: {
        content: {
          "application/json": {
            schema: GenerateBranchesBody,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        content: {
          "application/json": {
            schema: GenerateBranchesResponse,
          },
        },
        description: "Generated branch metadata",
      },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      500: { description: "Failed to generate branch names" },
    },
  }),
  async (c) => {
    const body = c.req.valid("json");
    const req = c.req.raw;

    const user = await stackServerAppJs.getUser({ tokenStore: req });
    if (!user) {
      throw new HTTPException(401, { message: "Unauthorized" });
    }
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) {
      throw new HTTPException(401, { message: "Unauthorized" });
    }

    const team = await verifyTeamAccess({ req, teamSlugOrId: body.teamSlugOrId });

    const convex = getConvex({ accessToken });

    try {
      const teamApiKeys = await convex.query(api.apiKeys.getAllForAgents, {
        teamSlugOrId: body.teamSlugOrId,
      });
      const apiKeys = mergeApiKeysWithEnv(teamApiKeys ?? {});

      const count = body.count ?? 1;

      if (!body.taskDescription && body.prTitle) {
        const kebabTitle = toKebabCase(body.prTitle);
        const baseBranchName = `cmux/${kebabTitle}`;
        const branchNames = generateBranchNamesFromBase(
          baseBranchName,
          count,
          body.uniqueId,
        );

        return c.json({
          branchNames,
          baseBranchName,
          prTitle: body.prTitle,
          usedFallback: false,
          providerName: null,
        });
      }

      if (count === 1) {
        const {
          branchName,
          baseBranchName,
          prTitle,
          usedFallback,
          providerName,
        } = await generateNewBranchName(
          body.taskDescription!,
          apiKeys,
          body.uniqueId,
        );

        trackModelUsage({
          userId: user.id ?? null,
          teamId: team.uuid,
          teamSlug: team.slug,
          teamSlugOrId: body.teamSlugOrId,
          providerName,
          modelName: resolveModelName(providerName),
          feature: "branch_generation",
          usedFallback,
          requestedCount: count,
        });

        return c.json({
          branchNames: [branchName],
          baseBranchName,
          prTitle,
          usedFallback,
          providerName,
        });
      }

      const {
        branchNames,
        baseBranchName,
        prTitle,
        usedFallback,
        providerName,
      } = await generateUniqueBranchNames(
        body.taskDescription!,
        count,
        apiKeys,
        body.uniqueId,
      );

      trackModelUsage({
        userId: user.id ?? null,
        teamId: team.uuid,
        teamSlug: team.slug,
        teamSlugOrId: body.teamSlugOrId,
        providerName,
        modelName: resolveModelName(providerName),
        feature: "branch_generation",
        usedFallback,
        requestedCount: count,
      });

      return c.json({
        branchNames,
        baseBranchName,
        prTitle,
        usedFallback,
        providerName,
      });
    } catch (error) {
      console.error("[BranchRoute] Failed to generate branches", error);
      throw new HTTPException(500, {
        message: "Failed to generate branch names",
      });
    }
  },
);
