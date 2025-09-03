import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { getConvex } from "@/lib/utils/get-convex";
import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import { api } from "@cmux/convex/api";
import { canonicalJSONStringify, sha256Hex } from "@/lib/utils/stableHash";

export const vscodeSettingsRouter = new OpenAPIHono();

const TeamQuery = z
  .object({
    team: z.string().min(1).openapi({ description: "Team slug or UUID" }),
  })
  .openapi("VSCodeTeamQuery");

const VSCodeSettingsPayload = z
  .object({
    settings: z.any().optional().openapi({ description: "User settings.json contents" }),
    keybindings: z.any().optional().openapi({ description: "User keybindings.json contents" }),
    snippets: z.any().optional().openapi({ description: "Record of snippet files -> JSON" }),
    extensions: z
      .array(z.string())
      .optional()
      .openapi({ description: "Array of extension identifiers (publisher.name)" }),
  })
  .openapi("VSCodeSettingsPayload");

const UpsertResponse = z
  .object({
    updated: z.boolean(),
    hash: z.string(),
    updatedAt: z.number(),
  })
  .openapi("VSCodeUpsertResponse");

const GetResponse = z
  .object({
    userId: z.string(),
    teamId: z.string(),
    settings: z.any().optional(),
    keybindings: z.any().optional(),
    snippets: z.any().optional(),
    extensions: z.array(z.string()).optional(),
    hash: z.string(),
    createdAt: z.number(),
    updatedAt: z.number(),
    _id: z.string(),
  })
  .nullable()
  .openapi("VSCodeGetResponse");

// GET: Fetch current VS Code settings for the authenticated user and team
vscodeSettingsRouter.openapi(
  createRoute({
    method: "get",
    path: "/vscode/settings",
    tags: ["VSCode"],
    summary: "Get VS Code settings for user/team",
    request: { query: TeamQuery },
    responses: {
      200: {
        description: "OK",
        content: { "application/json": { schema: GetResponse } },
      },
      401: { description: "Unauthorized" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);
    const { team } = c.req.valid("query");
    const convex = getConvex({ accessToken });
    const doc = await convex.query(api.vscodeSettings.get, { teamSlugOrId: team });
    return c.json(doc, 200);
  }
);

// POST: Upsert VS Code settings. Computes a stable hash and updates only on change.
vscodeSettingsRouter.openapi(
  createRoute({
    method: "post",
    path: "/vscode/settings",
    tags: ["VSCode"],
    summary: "Upsert VS Code settings for user/team",
    request: {
      query: TeamQuery,
      body: {
        required: true,
        content: { "application/json": { schema: VSCodeSettingsPayload } },
      },
    },
    responses: {
      200: {
        description: "Upserted or unchanged",
        content: { "application/json": { schema: UpsertResponse } },
      },
      401: { description: "Unauthorized" },
    },
  }),
  async (c) => {
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) return c.text("Unauthorized", 401);
    const { team } = c.req.valid("query");
    const body = c.req.valid("json");
    const convex = getConvex({ accessToken });

    const canonical = canonicalJSONStringify({
      settings: body.settings,
      keybindings: body.keybindings,
      snippets: body.snippets,
      extensions: body.extensions,
    });
    const hash = sha256Hex(canonical);

    const res = await convex.mutation(api.vscodeSettings.upsert, {
      teamSlugOrId: team,
      settings: body.settings,
      keybindings: body.keybindings,
      snippets: body.snippets,
      extensions: body.extensions,
      hash,
    });
    return c.json(res, 200);
  }
);

