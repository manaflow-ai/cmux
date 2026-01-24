import { headers } from "next/headers";
import { notFound, redirect } from "next/navigation";
import { GuidedOnboarding } from "@/components/preview/guided-onboarding";
import { getConvex } from "@/lib/utils/get-convex";
import { stackServerApp } from "@/lib/utils/stack";
import { api } from "@cmux/convex/api";
import {
  getTeamDisplayName,
  getTeamSlugOrId,
  type StackTeam,
} from "@/lib/team-utils";
import { env } from "@/lib/utils/www-env";
import { typedZid } from "@cmux/shared/utils/typed-zid";

type PageProps = {
  searchParams?: Promise<SearchParams>;
};

type SearchParams = Record<string, string | string[] | undefined>;

function buildConfigurePath(search: SearchParams | undefined): string {
  const params = new URLSearchParams();
  if (search) {
    Object.entries(search).forEach(([key, value]) => {
      if (Array.isArray(value)) {
        value.forEach((entry) => {
          if (entry) params.append(key, entry);
        });
      } else if (value) {
        params.set(key, value);
      }
    });
  }
  const query = params.toString();
  return query ? `/preview-new/configure?${query}` : "/preview-new/configure";
}

function getSearchValue(
  search: SearchParams | undefined,
  key: string
): string | null {
  if (!search) {
    return null;
  }
  const value = search[key];
  return Array.isArray(value) ? value[0] ?? null : value ?? null;
}

export default async function PreviewNewConfigurePage({ searchParams }: PageProps) {
  const resolvedSearch = await searchParams;
  const configurePath = buildConfigurePath(resolvedSearch);

  const user = await stackServerApp.getUser();

  // If user is not authenticated, redirect to sign-in
  if (!user) {
    const signInUrl = `/handler/sign-in?after_auth_return_to=${encodeURIComponent(configurePath)}`;
    return redirect(signInUrl);
  }

  // Try to get auth tokens and user data
  let accessToken: string | null = null;
  let teams: StackTeam[] = [];

  try {
    const [auth, teamsResult] = await Promise.all([
      user.getAuthJson(),
      user.listTeams(),
    ]);
    teams = teamsResult;
    accessToken = auth.accessToken;
  } catch (error) {
    console.error("[PreviewNewConfigurePage] Failed to fetch user data from Stack Auth", error);
  }

  // If accessToken is null, try creating a fresh session
  if (!accessToken) {
    console.log("[PreviewNewConfigurePage] accessToken is null, attempting to create fresh session");
    try {
      const freshSession = await user.createSession({ expiresInMillis: 24 * 60 * 60 * 1000 });
      const freshTokens = await freshSession.getTokens();
      if (freshTokens.accessToken) {
        accessToken = freshTokens.accessToken;
        console.log("[PreviewNewConfigurePage] Got fresh access token from new session");
        if (teams.length === 0) {
          try {
            teams = await user.listTeams();
          } catch (teamsError) {
            console.error("[PreviewNewConfigurePage] Failed to fetch teams", teamsError);
          }
        }
      }
    } catch (error) {
      console.error("[PreviewNewConfigurePage] Failed to create fresh session", error);
    }
  }

  // If we still don't have an access token, redirect to sign-in
  if (!accessToken) {
    console.error("[PreviewNewConfigurePage] No access token available after retry, redirecting to sign-in");
    const signInUrl = `/handler/sign-in?after_auth_return_to=${encodeURIComponent(configurePath)}`;
    return redirect(signInUrl);
  }

  if (teams.length === 0) {
    notFound();
  }

  const repo = getSearchValue(resolvedSearch, "repo");
  const installationId = getSearchValue(resolvedSearch, "installationId");
  const environmentId = getSearchValue(resolvedSearch, "environmentId");

  if (!repo) {
    notFound();
  }

  const searchTeam = getSearchValue(resolvedSearch, "team");

  const selectedTeam =
    teams.find(
      (team) =>
        Boolean(searchTeam) &&
        getTeamDisplayName(team).toLowerCase() === searchTeam?.toLowerCase()
    ) ||
    teams.find((team) => getTeamSlugOrId(team) === searchTeam) ||
    teams[0];
  const selectedTeamSlugOrId = getTeamSlugOrId(selectedTeam);

  const convex = getConvex({ accessToken });
  const providerConnections = await convex.query(api.github.listProviderConnections, {
    teamSlugOrId: selectedTeamSlugOrId,
  });

  const hasGithubAppInstallation = providerConnections.some(
    (connection) => connection.isActive,
  );

  if (!hasGithubAppInstallation) {
    const githubAppSlug = process.env.NEXT_PUBLIC_GITHUB_APP_SLUG;
    if (!githubAppSlug) {
      throw new Error("GitHub App slug is not configured");
    }

    const headerList = await headers();
    const host = headerList.get("x-forwarded-host") ?? headerList.get("host");
    const protocol = headerList.get("x-forwarded-proto") ?? "https";
    const returnUrl =
      host && configurePath.startsWith("/")
        ? `${protocol}://${host}${configurePath}`
        : configurePath;

    const { state } = await convex.mutation(api.github_app.mintInstallState, {
      teamSlugOrId: selectedTeamSlugOrId,
      returnUrl,
    });

    const url = new URL(`https://github.com/apps/${githubAppSlug}/installations/new`);
    url.searchParams.set("state", state);
    return redirect(url.toString());
  }

  let initialEnvVarsContent: string | null = null;

  if (environmentId) {
    try {
      const parsedEnvId = typedZid("environments").parse(environmentId);

      const environment = await convex.query(api.environments.get, {
        teamSlugOrId: selectedTeamSlugOrId,
        id: parsedEnvId,
      });

      if (environment) {
        try {
          const store = await stackServerApp.getDataVaultStore("cmux-snapshot-envs");
          const varsContent = await store.getValue(environment.dataVaultKey, {
            secret: env.STACK_DATA_VAULT_SECRET,
          });
          if (typeof varsContent === "string") {
            initialEnvVarsContent = varsContent;
          }
        } catch (error) {
          console.error("Failed to fetch environment vars from data vault", error);
        }
      }
    } catch (error) {
      console.error("Failed to fetch environment details", error);
    }
  }

  return (
    <GuidedOnboarding
      teamSlugOrId={selectedTeamSlugOrId}
      repo={repo}
      installationId={installationId}
      initialEnvVarsContent={initialEnvVarsContent}
    />
  );
}
