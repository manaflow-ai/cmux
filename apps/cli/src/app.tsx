import React, { useEffect, useState } from "react";
import { Box, Text, useApp } from "ink";
import Spinner from "ink-spinner";
import TextInput from "ink-text-input";
import type { ListEnvironmentsResponse } from "@cmux/www-openapi-client";
import { cliConfig } from "./config";
import {
  authenticateUser,
  type AuthenticatedSession,
} from "./auth";
import {
  describeTeam,
  fetchEnvironmentsForTeam,
  type TeamMembership,
} from "./cmuxClient";
import type { StackUser } from "./auth";

type Phase =
  | { kind: "authenticating" }
  | { kind: "select-team"; session: AuthenticatedSession }
  | {
      kind: "fetching";
      session: AuthenticatedSession;
      team: TeamMembership;
    }
  | {
      kind: "success";
      session: AuthenticatedSession;
      team: TeamMembership;
      environments: ListEnvironmentsResponse;
    }
  | { kind: "error"; message: string };

const getUserEmail = (user: StackUser): string | null => {
  if (user.primary_email) {
    return user.primary_email;
  }
  const primary = user.emails?.find((entry) => entry.primary);
  if (primary?.email) {
    return primary.email;
  }
  return user.emails && user.emails.length > 0 ? user.emails[0]?.email ?? null : null;
};

const getUserDisplayName = (user: StackUser): string => {
  const email = getUserEmail(user);
  if (user.display_name && user.display_name.trim().length > 0) {
    return user.display_name;
  }
  return email ?? user.id;
};

const identifierForTeam = (team: TeamMembership): string =>
  team.team.slug ?? team.team.teamId;

const defaultTeamMatch = (
  memberships: TeamMembership[],
  prefer: string | null,
): TeamMembership | null => {
  if (!prefer) {
    return null;
  }
  const normalized = prefer.trim().toLowerCase();
  return (
    memberships.find((membership) => {
      const slug = membership.team.slug?.toLowerCase();
      if (slug && slug === normalized) {
        return true;
      }
      return membership.team.teamId.toLowerCase() === normalized;
    }) ?? null
  );
};

export const App: React.FC = () => {
  const { exit } = useApp();
  const [phase, setPhase] = useState<Phase>({ kind: "authenticating" });
  const [statusMessage, setStatusMessage] = useState<string>(
    "Starting authentication…",
  );
  const [loginUrl, setLoginUrl] = useState<string | null>(null);
  const [teamInput, setTeamInput] = useState<string>(
    cliConfig.defaultTeamSlugOrId ?? "",
  );
  const [teamInputError, setTeamInputError] = useState<string | null>(null);

  useEffect(() => {
    authenticateUser(cliConfig, {
      onBrowserUrl: (url) => {
        setLoginUrl(url);
      },
      onStatus: (message) => {
        setStatusMessage(message);
      },
    })
      .then((session) => {
        if (session.memberships.length === 0) {
          setPhase({
            kind: "error",
            message:
              "No team memberships found for this user. You need at least one team to list environments.",
          });
          return;
        }

        const preferredTeam =
          defaultTeamMatch(session.memberships, cliConfig.defaultTeamSlugOrId) ??
          (session.memberships.length === 1
            ? session.memberships[0]
            : null);

        if (preferredTeam) {
          setStatusMessage("Loading environments…");
          setPhase({
            kind: "fetching",
            session,
            team: preferredTeam,
          });
          return;
        }

        setStatusMessage(
          "Multiple teams found. Please pick one to list environments.",
        );
        setPhase({ kind: "select-team", session });
      })
      .catch((error) => {
        const message =
          error instanceof Error
            ? error.message
            : "Unknown error during authentication.";
        setPhase({ kind: "error", message });
      });
  }, []);

  useEffect(() => {
    if (phase.kind !== "fetching") {
      return;
    }

    const { session, team } = phase;
    const teamIdentifier = identifierForTeam(team);

    fetchEnvironmentsForTeam(
      cliConfig,
      session.context,
      teamIdentifier,
    )
      .then((environments) => {
        setPhase({
          kind: "success",
          session,
          team,
          environments,
        });
      })
      .catch((error) => {
        const message =
          error instanceof Error
            ? error.message
            : "Failed to load environments.";
        setPhase({ kind: "error", message });
      });
  }, [phase]);

  useEffect(() => {
    if (phase.kind !== "success") {
      return;
    }
    const timer = setTimeout(() => {
      exit();
    }, 150);
    return () => {
      clearTimeout(timer);
    };
  }, [phase, exit]);

  const renderHeader = () => (
    <Box flexDirection="column" marginBottom={1}>
      <Text>
        <Text color="cyanBright">cmux CLI</Text> · Stack Auth Login
      </Text>
    </Box>
  );

  const renderAuthenticator = () => (
    <Box flexDirection="column">
      <Text>
        <Text color="green">
          <Spinner type="dots" />
        </Text>{" "}
        {statusMessage}
      </Text>
      {loginUrl ? (
        <Text>
          If your browser did not open automatically, visit{" "}
          <Text color="cyan">{loginUrl}</Text>
        </Text>
      ) : null}
    </Box>
  );

  const renderTeamSelection = (session: AuthenticatedSession) => {
    const user = session.context.user;
    const email = getUserEmail(user);
    const description = `${getUserDisplayName(user)}${email ? ` · ${email}` : ""}`;
    return (
      <Box flexDirection="column">
        <Text>{description}</Text>
        <Box flexDirection="column" marginY={1}>
          <Text color="gray">Available teams:</Text>
          {session.memberships.map((membership) => (
            <Text key={membership.team.teamId}>
              - {describeTeam(membership)}
            </Text>
          ))}
        </Box>
        <Text color="gray">
          Enter a team slug or team UUID to list its environments:
        </Text>
        <TextInput
          value={teamInput}
          onChange={(value) => {
            setTeamInputError(null);
            setTeamInput(value);
          }}
          onSubmit={(value) => {
            const trimmed = value.trim();
            if (trimmed.length === 0) {
              setTeamInputError("Please enter a team identifier.");
              return;
            }
            const match = defaultTeamMatch(session.memberships, trimmed);
            if (!match) {
              setTeamInputError(
                `Could not find a team matching "${trimmed}".`,
              );
              return;
            }
            setStatusMessage("Loading environments…");
            setPhase({ kind: "fetching", session, team: match });
          }}
        />
        {teamInputError ? (
          <Text color="red">{teamInputError}</Text>
        ) : null}
      </Box>
    );
  };

  const renderSuccess = (
    session: AuthenticatedSession,
    team: TeamMembership,
    environments: ListEnvironmentsResponse,
  ) => {
    const user = session.context.user;
    const email = getUserEmail(user);
    const displayName = getUserDisplayName(user);
    return (
      <Box flexDirection="column" gap={1}>
        <Text color="green">Authenticated as {displayName}</Text>
        {email ? <Text color="gray">Email: {email}</Text> : null}
        <Text>
          Team: <Text color="cyan">{describeTeam(team)}</Text>
        </Text>
        <Text>
          Found{" "}
          <Text color="magenta">
            {environments.length} environment
            {environments.length === 1 ? "" : "s"}
          </Text>
        </Text>
        {environments.length === 0 ? (
          <Text color="yellow">No environments configured yet.</Text>
        ) : (
          <Box flexDirection="column">
            {environments.map((environment) => (
              <Box key={environment.id} flexDirection="column" marginBottom={1}>
                <Text>
                  <Text color="cyan">{environment.name}</Text>{" "}
                  <Text color="gray">#{environment.id}</Text>
                </Text>
                <Text color="gray">
                  Snapshot {environment.morphSnapshotId} · Updated{" "}
                  {new Date(environment.updatedAt).toLocaleString()}
                </Text>
                {environment.exposedPorts &&
                environment.exposedPorts.length > 0 ? (
                  <Text color="gray">
                    Exposed ports: {environment.exposedPorts.join(", ")}
                  </Text>
                ) : null}
                {environment.description ? (
                  <Text color="gray">
                    Description: {environment.description}
                  </Text>
                ) : null}
              </Box>
            ))}
          </Box>
        )}
      </Box>
    );
  };

  const renderError = (message: string) => (
    <Box flexDirection="column">
      <Text color="red">Error: {message}</Text>
    </Box>
  );

  return (
    <Box flexDirection="column">
      {renderHeader()}
      {phase.kind === "authenticating" ? renderAuthenticator() : null}
      {phase.kind === "select-team"
        ? renderTeamSelection(phase.session)
        : null}
      {phase.kind === "fetching" ? (
        <Text>
          <Text color="green">
            <Spinner type="line" />
          </Text>{" "}
          {statusMessage}
        </Text>
      ) : null}
      {phase.kind === "success"
        ? renderSuccess(phase.session, phase.team, phase.environments)
        : null}
      {phase.kind === "error" ? renderError(phase.message) : null}
    </Box>
  );
};
