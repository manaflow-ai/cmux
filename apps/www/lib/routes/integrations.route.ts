import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { stackServerApp } from "@/lib/utils/stack";
import { ConvexHttpClient } from "convex/browser";
import { api } from "@cmux/convex/api";

const CLIENT_BASE = process.env.CLIENT_URL || "http://localhost:5173";
const CONVEX_URL = process.env.VITE_CONVEX_URL || "http://127.0.0.1:9777";

export const integrationsRouter = new OpenAPIHono();

const SetupQuery = z
  .object({
    installation_id: z.coerce.number(),
    // We pass teamSlugOrId as state
    state: z.string().min(1),
    setup_action: z.string().optional(),
  })
  .openapi("GitHubSetupQuery");

integrationsRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/integrations/github/setup",
    tags: ["Integrations"],
    summary: "GitHub App Setup URL handler",
    request: {
      query: SetupQuery,
    },
    responses: {
      302: {
        description: "Redirect to client",
      },
      401: { description: "Unauthorized" },
      400: { description: "Bad request" },
    },
  }),
  async (c) => {
    const { installation_id, state } = c.req.valid("query");

    // Require a logged-in user so we can securely set team mapping
    const user = await stackServerApp.getUser({ tokenStore: c.req.raw });
    if (!user) return c.text("Unauthorized", 401);
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) return c.text("Unauthorized", 401);

    // Assign installation to the provided teamSlugOrId (state) using Convex auth
    const convex = new ConvexHttpClient(CONVEX_URL);
    convex.setAuth(accessToken);
    try {
      await convex.mutation(api.github.assignProviderConnectionToTeam, {
        teamSlugOrId: state,
        installationId: installation_id,
      });
    } catch (e) {
      console.error("Failed to assign provider connection:", e);
      return c.text("Assignment failed", 400);
    }

    // Redirect to client environments page for this team
    const target = `${CLIENT_BASE}/${encodeURIComponent(state)}/environments`;
    return c.redirect(target, 302);
  }
);

// Lightweight alias to support legacy/simple Setup URL like /api/github_setup
integrationsRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/github_setup",
    tags: ["Integrations"],
    summary: "GitHub App Setup URL handler (alias)",
    request: { query: SetupQuery },
    responses: { 302: { description: "Redirect to client" }, 401: { description: "Unauthorized" }, 400: { description: "Bad request" } },
  }),
  async (c) => {
    const { installation_id, state } = c.req.valid("query");

    const user = await stackServerApp.getUser({ tokenStore: c.req.raw });
    if (!user) return c.text("Unauthorized", 401);
    const { accessToken } = await user.getAuthJson();
    if (!accessToken) return c.text("Unauthorized", 401);

    const convex = new ConvexHttpClient(CONVEX_URL);
    convex.setAuth(accessToken);
    try {
      await convex.mutation(api.github.assignProviderConnectionToTeam, {
        teamSlugOrId: state,
        installationId: installation_id,
      });
    } catch (e) {
      console.error("Failed to assign provider connection (alias):", e);
      return c.text("Assignment failed", 400);
    }

    const target = `${CLIENT_BASE}/${encodeURIComponent(state)}/environments`;
    return c.redirect(target, 302);
  }
);
