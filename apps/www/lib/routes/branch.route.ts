import { trackModelUsage } from "@/lib/analytics/posthog-server";
import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import {
  generateBranchNamesFromBase,
  generateNewBranchName,
  generateUniqueBranchNames,
  mergeApiKeysWithEnv,
  toKebabCase,
} from "@/lib/utils/branch-name-generator";
import { getConvex } from "@/lib/utils/get-convex";
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

    const accessToken = await getAccessTokenFromRequest(req);
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

        trackModelUsage({
          team,
          modelProvider: "manual_pr_title",
          usedFallback: false,
          branchCount: branchNames.length,
          taskDescriptionLength: body.taskDescription?.length ?? null,
          taskDescriptionProvided: Boolean(body.taskDescription),
          prTitleProvided: Boolean(body.prTitle),
          uniqueIdProvided: Boolean(body.uniqueId),
          source: "branch.fromTitle",
        });

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
          team,
          modelProvider: providerName,
          usedFallback,
          branchCount: 1,
          taskDescriptionLength: body.taskDescription?.length ?? null,
          taskDescriptionProvided: Boolean(body.taskDescription),
          prTitleProvided: Boolean(body.prTitle),
          uniqueIdProvided: Boolean(body.uniqueId),
          source: "branch.generate",
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
        team,
        modelProvider: providerName,
        usedFallback,
        branchCount: branchNames.length,
        taskDescriptionLength: body.taskDescription?.length ?? null,
        taskDescriptionProvided: Boolean(body.taskDescription),
        prTitleProvided: Boolean(body.prTitle),
        uniqueIdProvided: Boolean(body.uniqueId),
        source: "branch.generateUnique",
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
