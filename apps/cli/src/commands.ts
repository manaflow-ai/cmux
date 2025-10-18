import process from "node:process";
import type { ListEnvironmentsResponse } from "@cmux/www-openapi-client";
import { cliConfig } from "./config";
import type { StackUser } from "./auth";
import {
  authenticateUser,
  type AuthenticatedSession,
  type AuthenticationCallbacks,
  clearStoredRefreshToken,
} from "./auth";
import {
  describeTeam,
  fetchEnvironmentsForTeam,
  type TeamMembership,
} from "./cmuxClient";

interface CommandOptions {
  quiet?: boolean;
}

const statusLogger = (
  quiet: boolean | undefined,
): AuthenticationCallbacks["onStatus"] => {
  if (quiet) {
    return undefined;
  }
  return (status: string) => {
    process.stderr.write(`- ${status}\n`);
  };
};

const browserLogger = (
  quiet: boolean | undefined,
): AuthenticationCallbacks["onBrowserUrl"] => {
  if (quiet) {
    return undefined;
  }
  return (url: string) => {
    process.stderr.write(`Open the following URL to continue: ${url}\n`);
  };
};

const findTeam = (
  memberships: TeamMembership[],
  slugOrId: string,
): TeamMembership | undefined => {
  const normalized = slugOrId.trim().toLowerCase();
  return memberships.find((membership) => {
    const slug = membership.team.slug?.toLowerCase();
    if (slug && slug === normalized) {
      return true;
    }
    return membership.team.teamId.toLowerCase() === normalized;
  });
};

const authenticate = async (
  options: CommandOptions = {},
): Promise<AuthenticatedSession> => {
  return authenticateUser(cliConfig, {
    onBrowserUrl: browserLogger(options.quiet),
    onStatus: statusLogger(options.quiet),
  });
};

const userDisplayName = (user: StackUser): string => {
  if (user.display_name && user.display_name.trim().length > 0) {
    return user.display_name;
  }
  const email =
    user.primary_email ??
    user.emails?.find((entry) => entry.primary)?.email ??
    user.emails?.[0]?.email;
  return email ?? user.id;
};

export const login = async (options: CommandOptions = {}) => {
  const session = await authenticate(options);
  const userName = userDisplayName(session.context.user);
  process.stdout.write(`Logged in as ${userName}.\n`);
};

export const logout = async () => {
  await clearStoredRefreshToken(cliConfig.stack.projectId);
  process.stdout.write("Cleared stored credentials.\n");
};

export const listTeams = async (options: CommandOptions = {}) => {
  const session = await authenticate(options);
  if (session.memberships.length === 0) {
    process.stdout.write("No team memberships found.\n");
    return;
  }
  session.memberships.forEach((membership) => {
    process.stdout.write(`${describeTeam(membership)}\n`);
  });
};

interface ListEnvironmentsOptions extends CommandOptions {
  team: string;
  json?: boolean;
}

const formatEnvironmentsText = (
  environments: ListEnvironmentsResponse,
): string => {
  if (environments.length === 0) {
    return "No environments found.";
  }
  const lines = environments.map((env) => {
    const parts = [`${env.name} (${env.id})`];
    if (env.description) {
      parts.push(`description: ${env.description}`);
    }
    parts.push(`snapshot: ${env.morphSnapshotId ?? "n/a"}`);
    return parts.join(" | ");
  });
  return lines.join("\n");
};

export const listEnvironments = async (
  options: ListEnvironmentsOptions,
) => {
  const session = await authenticate(options);
  const team = findTeam(session.memberships, options.team);
  if (!team) {
    throw new Error(
      `Team "${options.team}" not found. Use \`cmux-cli teams\` to list available teams.`,
    );
  }

  const environments = await fetchEnvironmentsForTeam(
    cliConfig,
    session.context,
    team.team.slug ?? team.team.teamId,
  );

  if (options.json) {
    process.stdout.write(`${JSON.stringify(environments, null, 2)}\n`);
    return;
  }

  process.stdout.write(`${formatEnvironmentsText(environments)}\n`);
};
