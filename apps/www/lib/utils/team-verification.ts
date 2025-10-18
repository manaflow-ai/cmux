import { api } from "@cmux/convex/api";
import { HTTPException } from "hono/http-exception";
import { getAccessTokenFromRequest } from "./auth";
import { getConvex } from "./get-convex";

/**
 * Verifies that a user has access to a team and returns the team object.
 * Throws HTTPException if the user doesn't have access.
 */
export async function verifyTeamAccess({
  req,
  accessToken,
  teamSlugOrId,
}: {
  req?: Request;
  accessToken?: string | null;
  teamSlugOrId: string;
}): Promise<{
  uuid: string;
  slug: string | null;
  displayName: string | null;
  name: string | null;
}> {
  let token = accessToken;
  if (!token) {
    if (!req) {
      throw new HTTPException(401, {
        message: "Unauthorized: No access token",
      });
    }
    token = await getAccessTokenFromRequest(req);
  }
  if (!token) {
    throw new HTTPException(401, { message: "Unauthorized: No access token" });
  }

  const convexClient = getConvex({ accessToken: token });

  try {
    // This query will throw if the user doesn't have access to the team
    const team = await convexClient.query(api.teams.get, { teamSlugOrId });

    if (!team) {
      throw new HTTPException(404, { message: "Team not found" });
    }

    return team;
  } catch (error) {
    if (error instanceof HTTPException) {
      throw error;
    }
    // If Convex throws a "Forbidden" error, convert to HTTPException
    if (error instanceof Error && error.message.includes("Forbidden")) {
      throw new HTTPException(403, {
        message: "Forbidden: Not a member of this team",
      });
    }
    throw new HTTPException(500, { message: "Failed to verify team access" });
  }
}
