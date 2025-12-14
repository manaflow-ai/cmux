import { getConvex } from "@/lib/utils/get-convex";
import { getUserFromRequest } from "@/lib/utils/auth";
import { stackServerApp } from "@/lib/utils/stack";
import { api } from "@cmux/convex/api";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";

const teamsRouter = new OpenAPIHono();

const CreateTeamRequestSchema = z
  .object({
    displayName: z
      .string()
      .trim()
      .min(1)
      .max(64)
      .openapi({
        description: "Human-friendly team name",
        example: "Frontend Wizards",
      }),
    slug: z
      .string()
      .trim()
      .min(3)
      .max(48)
      .regex(/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/)
      .openapi({
        description:
          "Slug used in URLs. Lowercase letters, numbers, and hyphens. Must start and end with a letter or number.",
        example: "frontend-wizards",
      }),
    inviteEmails: z
      .array(z.string().trim().email())
      .max(20)
      .optional()
      .openapi({
        description: "Optional list of teammate emails to invite",
        example: ["teammate@example.com"],
      }),
  })
  .openapi("CreateTeamRequest");

const CreateTeamResponseSchema = z
  .object({
    teamId: z.string().openapi({ description: "Stack team ID" }),
    displayName: z
      .string()
      .openapi({ description: "Display name saved in Stack", example: "Frontend Wizards" }),
    slug: z
      .string()
      .openapi({ description: "Slug stored in Convex", example: "frontend-wizards" }),
    invitesSent: z
      .number()
      .openapi({ description: "Number of invite emails sent", example: 1 }),
  })
  .openapi("CreateTeamResponse");

const ErrorResponseSchema = z
  .object({
    code: z.number(),
    message: z.string(),
  })
  .openapi("CreateTeamErrorResponse");

const TeamSchema = z
  .object({
    id: z.string().openapi({ description: "Team ID" }),
    displayName: z.string().openapi({ description: "Display name", example: "Frontend Wizards" }),
    slug: z.string().nullable().openapi({ description: "URL slug", example: "frontend-wizards" }),
  })
  .openapi("Team");

const ListTeamsResponseSchema = z
  .object({
    teams: z.array(TeamSchema),
  })
  .openapi("ListTeamsResponse");

const SLUG_POLL_INTERVAL_MS = 400;
const SLUG_POLL_TIMEOUT_MS = 15_000;

function normalizeSlug(input: string): string {
  return input.trim().toLowerCase();
}

function validateSlug(slug: string): void {
  const normalized = normalizeSlug(slug);
  if (normalized.length < 3 || normalized.length > 48) {
    throw new Error("Slug must be 3–48 characters long");
  }
  if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(normalized)) {
    throw new Error(
      "Slug can contain lowercase letters, numbers, and hyphens, and must start/end with a letter or number"
    );
  }
}

async function wait(ms: number): Promise<void> {
  await new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

// GET /teams - List user's teams
teamsRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/teams",
    tags: ["Teams"],
    summary: "List user's teams",
    responses: {
      200: {
        description: "List of teams",
        content: {
          "application/json": {
            schema: ListTeamsResponseSchema,
          },
        },
      },
      401: {
        description: "Unauthorized",
        content: {
          "application/json": {
            schema: ErrorResponseSchema,
          },
        },
      },
    },
  }),
  async (c) => {
    const user = await getUserFromRequest(c.req.raw);
    if (!user) {
      return c.json({ code: 401, message: "Unauthorized" }, 401);
    }

    const authJson = await user.getAuthJson();
    if (!authJson.accessToken) {
      return c.json({ code: 401, message: "Unauthorized" }, 401);
    }

    const stackTeams = await user.listTeams();
    const convex = getConvex({ accessToken: authJson.accessToken });

    // Fetch slugs from Convex for each team
    const teams = await Promise.all(
      stackTeams.map(async (team) => {
        let slug: string | null = null;
        try {
          const convexTeam = await convex.query(api.teams.get, { teamSlugOrId: team.id });
          slug = convexTeam?.slug ?? null;
        } catch {
          // Team might not exist in Convex yet
        }
        return {
          id: team.id,
          displayName: team.displayName,
          slug,
        };
      })
    );

    return c.json({ teams }, 200);
  }
);

teamsRouter.openapi(
  createRoute({
    method: "post" as const,
    path: "/teams",
    tags: ["Teams"],
    summary: "Create a new team",
    request: {
      body: {
        content: {
          "application/json": {
            schema: CreateTeamRequestSchema,
          },
        },
        required: true,
      },
    },
    responses: {
      201: {
        description: "Team created",
        content: {
          "application/json": {
            schema: CreateTeamResponseSchema,
          },
        },
      },
      400: {
        description: "Invalid input",
        content: {
          "application/json": {
            schema: ErrorResponseSchema,
          },
        },
      },
      401: {
        description: "Unauthorized",
        content: {
          "application/json": {
            schema: ErrorResponseSchema,
          },
        },
      },
      409: {
        description: "Slug conflict",
        content: {
          "application/json": {
            schema: ErrorResponseSchema,
          },
        },
      },
      504: {
        description: "Timed out while syncing",
        content: {
          "application/json": {
            schema: ErrorResponseSchema,
          },
        },
      },
      500: {
        description: "Failed to create team",
        content: {
          "application/json": {
            schema: ErrorResponseSchema,
          },
        },
      },
    },
  }),
  async (c) => {
    const body = c.req.valid("json");
    const trimmedName = body.displayName.trim();
    const normalizedSlug = normalizeSlug(body.slug);
    const inviteEmails = Array.from(
      new Set((body.inviteEmails ?? []).map((email) => email.trim()).filter((email) => email.length > 0))
    );

    if (trimmedName.length === 0) {
      return c.json({ code: 400, message: "Display name is required" }, 400);
    }

    try {
      validateSlug(normalizedSlug);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Invalid slug";
      return c.json({ code: 400, message }, 400);
    }

    const user = await stackServerApp.getUser({ tokenStore: c.req.raw, or: "return-null" });
    if (!user) {
      return c.json({ code: 401, message: "Unauthorized" }, 401);
    }

    const authJson = await user.getAuthJson();
    if (!authJson.accessToken) {
      return c.json({ code: 401, message: "Unauthorized" }, 401);
    }

    const convex = getConvex({ accessToken: authJson.accessToken });

    try {
      const existing = await convex
        .query(api.teams.get, { teamSlugOrId: normalizedSlug })
        .catch(() => null);
      if (existing && existing.slug === normalizedSlug) {
        return c.json({ code: 409, message: "Slug is already taken" }, 409);
      }

      const createdTeam = await user.createTeam({ displayName: trimmedName });

      try {
        const metadata =
          createdTeam.clientMetadata &&
          typeof createdTeam.clientMetadata === "object" &&
          createdTeam.clientMetadata !== null
            ? (createdTeam.clientMetadata as Record<string, unknown>)
            : {};
        await createdTeam.update({
          clientMetadata: {
            ...metadata,
            slug: normalizedSlug,
          },
        });
      } catch (metadataError) {
        console.error("Failed to persist slug in Stack metadata", metadataError);
      }

      let invitesSent = 0;
      for (const email of inviteEmails) {
        try {
          await createdTeam.inviteUser({ email });
          invitesSent += 1;
        } catch (inviteError) {
          console.error("Failed to invite teammate", { email, inviteError });
        }
      }

      const start = Date.now();
      let slugSet = false;
      let lastError: unknown;
      while (Date.now() - start < SLUG_POLL_TIMEOUT_MS) {
        try {
          await convex.mutation(api.teams.setSlug, {
            teamSlugOrId: createdTeam.id,
            slug: normalizedSlug,
          });
          slugSet = true;
          break;
        } catch (error) {
          lastError = error;
          if (error instanceof Error && error.message.includes("Slug is already taken")) {
            return c.json({ code: 409, message: error.message }, 409);
          }
        }
        await wait(SLUG_POLL_INTERVAL_MS);
      }

      if (!slugSet) {
        console.error("Timed out waiting for team to sync in Convex", {
          teamId: createdTeam.id,
          lastError,
        });
        return c.json(
          { code: 504, message: "Timed out while syncing the new team" },
          504
        );
      }

      return c.json(
        {
          teamId: createdTeam.id,
          displayName: createdTeam.displayName,
          slug: normalizedSlug,
          invitesSent,
        },
        201
      );
    } catch (error) {
      console.error("Failed to create team via Stack", error);
      return c.json({ code: 500, message: "Failed to create team" }, 500);
    }
  }
);

export { teamsRouter };
