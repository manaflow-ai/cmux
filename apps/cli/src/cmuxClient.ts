import { ConvexHttpClient } from "convex/browser";
import {
  getApiEnvironments,
  type ListEnvironmentsResponse,
} from "@cmux/www-openapi-client";
import { createClient } from "@cmux/www-openapi-client/client";
import { makeFunctionReference } from "convex/server";
import { z } from "zod";

import type { CLIConfig } from "./config";
import type { StackUser } from "./auth";

export interface TeamMembership {
  teamId: string;
  userId: string;
  role?: "owner" | "member";
  createdAt: number;
  updatedAt: number;
  team: {
    teamId: string;
    slug?: string | null;
    displayName?: string | null;
    name?: string | null;
  };
}

export interface AuthenticatedContext {
  refreshToken: string;
  accessToken: string;
  user: StackUser;
}

export async function fetchTeamMemberships(
  config: CLIConfig,
  accessToken: string,
): Promise<TeamMembership[]> {
  const convex = new ConvexHttpClient(config.convexUrl);
  convex.setAuth(accessToken);
  const listTeamMembershipsRef = makeFunctionReference<
    "query",
    Record<string, never>,
    unknown
  >("teams:listTeamMemberships");

  const raw = (await convex.query(
    listTeamMembershipsRef,
    {},
  )) as unknown;

  const parsed = membershipsSchema.parse(raw);

  return parsed.map((membership) => ({
    teamId: membership.teamId,
    userId: membership.userId,
    role: membership.role ?? undefined,
    createdAt: membership.createdAt,
    updatedAt: membership.updatedAt,
    team: {
      teamId: membership.team?.teamId ?? membership.teamId,
      slug: membership.team?.slug ?? null,
      displayName: membership.team?.displayName ?? null,
      name: membership.team?.name ?? null,
    },
  }));
}

export async function fetchEnvironmentsForTeam(
  config: CLIConfig,
  context: AuthenticatedContext,
  teamSlugOrId: string,
): Promise<ListEnvironmentsResponse> {
  const cookieHeader = formatStackCookie(
    config.stack.projectId,
    context.refreshToken,
    context.accessToken,
  );

  const openApiClient = createClient({
    baseUrl: config.wwwOrigin,
  });

  const result = await getApiEnvironments({
    query: { teamSlugOrId },
    headers: {
      Cookie: cookieHeader,
      Accept: "application/json",
    },
    client: openApiClient,
    responseStyle: "data",
    throwOnError: true,
  });

  if (!result || !("data" in result) || !result.data) {
    throw new Error("Failed to load environments (empty response).");
  }

  return result.data;
}

function formatStackCookie(
  projectId: string,
  refreshToken: string,
  accessToken: string,
): string {
  const refreshCookieName = `stack-refresh-${projectId}`;
  const cookieParts = [
    `${refreshCookieName}=${encodeURIComponent(refreshToken)}`,
    `stack-access=${encodeURIComponent(accessToken)}`,
  ];
  return cookieParts.join("; ");
}

export function describeTeam(membership: TeamMembership): string {
  const identifier = membership.team.slug ?? membership.team.teamId;
  const label =
    membership.team.displayName ??
    membership.team.name ??
    membership.team.slug ??
    membership.team.teamId;
  const role = membership.role ? ` (${membership.role})` : "";
  return `${label}${role} – ${identifier}`;
}

const teamSchema = z
  .object({
    teamId: z.string(),
    slug: z.string().nullable().optional(),
    displayName: z.string().nullable().optional(),
    name: z.string().nullable().optional(),
  })
  .passthrough();

const membershipSchema = z
  .object({
    teamId: z.string(),
    userId: z.string(),
    role: z.union([z.literal("owner"), z.literal("member")]).optional(),
    createdAt: z.number(),
    updatedAt: z.number(),
    team: teamSchema.optional(),
  })
  .passthrough();

const membershipsSchema = z.array(membershipSchema);
