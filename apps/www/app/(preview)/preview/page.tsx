import type { Metadata } from "next";
import { waitUntil } from "@vercel/functions";
import { stackServerApp } from "@/lib/utils/stack";
import { getConvex } from "@/lib/utils/get-convex";
import { api } from "@cmux/convex/api";
import { PreviewDashboard } from "@/components/preview/preview-dashboard";
import {
  getTeamDisplayName,
  getTeamSlugOrId,
  type StackTeam,
} from "@/lib/team-utils";

export const metadata: Metadata = {
  title: "Screenshot previews for GitHub PRs",
  description:
    "Code review agent that takes screenshots of code diffs involving UI changes. Automatically capture and preview visual changes in your pull requests.",
  openGraph: {
    title: "Screenshot previews for GitHub PRs",
    description:
      "Code review agent that takes screenshots of code diffs involving UI changes",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Screenshot previews for GitHub PRs",
    description:
      "Code review agent that takes screenshots of code diffs involving UI changes",
  },
};

export const dynamic = "force-dynamic";

type PageProps = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

type PreviewConfigListItem = {
  id: string;
  repoFullName: string;
  environmentId: string | null;
  repoInstallationId: number | null;
  repoDefaultBranch: string | null;
  status: "active" | "paused" | "disabled";
  lastRunAt: number | null;
  teamSlugOrId: string;
  teamName: string;
};

type TeamOption = {
  slugOrId: string;
  displayName: string;
};

type PreviewPaywallState = {
  isBlocked: boolean;
  hasPaid: boolean;
  usedRuns: number;
  freeLimit: number;
  productId: string;
};

function serializeProviderConnections(
  connections: Array<{
    id: string;
    installationId: number;
    accountLogin: string | null | undefined;
    accountType: string | null | undefined;
    isActive: boolean;
  }>
) {
  return connections.map((conn) => ({
    id: conn.id,
    installationId: conn.installationId,
    accountLogin: conn.accountLogin ?? null,
    accountType: conn.accountType ?? null,
    isActive: conn.isActive,
  }));
}

// Helper function to render the unauthenticated view
function renderUnauthenticatedView() {
  return (
    <div className="relative isolate min-h-dvh bg-[#05050a] text-white flex justify-center">
      <svg
        className="absolute inset-0 -z-10 w-full h-full -mx-8 sm:mx-0"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 832 252"
        fill="none"
        preserveAspectRatio="none"
      >
        <ellipse className="sm:hidden" cx="446" cy="96" rx="500" ry="126" fill="url(#paint0_radial_preview_unauth_sm)" />
        <ellipse className="hidden sm:block" cx="446" cy="96" rx="416" ry="126" fill="url(#paint0_radial_preview_unauth)" />
        <defs>
          <radialGradient
            id="paint0_radial_preview_unauth_sm"
            cx="0"
            cy="0"
            r="1"
            gradientUnits="userSpaceOnUse"
            gradientTransform="translate(446 96) scale(500 126)"
          >
            <stop stopColor="rgba(4,120,255,0.25)" />
            <stop offset="1" stopColor="rgba(4,120,255,0)" />
          </radialGradient>
          <radialGradient
            id="paint0_radial_preview_unauth"
            cx="0"
            cy="0"
            r="1"
            gradientUnits="userSpaceOnUse"
            gradientTransform="translate(446 96) scale(416 126)"
          >
            <stop stopColor="rgba(4,120,255,0.25)" />
            <stop offset="1" stopColor="rgba(4,120,255,0)" />
          </radialGradient>
        </defs>
      </svg>

      <PreviewDashboard
        selectedTeamSlugOrId=""
        teamOptions={[]}
        providerConnectionsByTeam={{}}
        isAuthenticated={false}
        previewConfigs={[]}
      />
    </div>
  );
}

export default async function PreviewLandingPage({ searchParams }: PageProps) {
  // Wrap the entire page in try-catch to prevent 500 errors
  // If anything fails, show the unauthenticated view so users can try signing in again
  let user;
  try {
    user = await stackServerApp.getUser();
  } catch (error) {
    console.error("[PreviewLandingPage] Failed to get user from Stack Auth", error);
    return renderUnauthenticatedView();
  }

  const resolvedSearch = await searchParams;

  if (!user) {
    return renderUnauthenticatedView();
  }

  // Try to get auth tokens and user data
  // Wrap in try-catch to handle any Stack Auth API errors gracefully
  let accessToken: string | null = null;
  let teams: StackTeam[] = [];
  let githubAccount: Awaited<ReturnType<typeof user.getConnectedAccount>> = null;
  let gitlabAccount: Awaited<ReturnType<typeof user.getConnectedAccount>> = null;
  let bitbucketAccount: Awaited<ReturnType<typeof user.getConnectedAccount>> = null;

  try {
    const [auth, teamsResult, github, gitlab, bitbucket] = await Promise.all([
      user.getAuthJson(),
      user.listTeams(),
      user.getConnectedAccount("github"),
      user.getConnectedAccount("gitlab"),
      user.getConnectedAccount("bitbucket"),
    ]);
    teams = teamsResult;
    githubAccount = github;
    gitlabAccount = gitlab;
    bitbucketAccount = bitbucket;
    accessToken = auth.accessToken;
  } catch (error) {
    console.error("[PreviewLandingPage] Failed to fetch user data from Stack Auth", error);
    // Fall through to try creating a fresh session
  }

  // If accessToken is null, try creating a fresh session to get valid tokens
  // This can happen right after OAuth sign-in when tokens aren't fully propagated
  if (!accessToken) {
    console.log("[PreviewLandingPage] accessToken is null, attempting to create fresh session");
    try {
      const freshSession = await user.createSession({ expiresInMillis: 24 * 60 * 60 * 1000 });
      const freshTokens = await freshSession.getTokens();
      if (freshTokens.accessToken) {
        accessToken = freshTokens.accessToken;
        console.log("[PreviewLandingPage] Got fresh access token from new session");
        // Also try to fetch teams if we didn't get them earlier
        if (teams.length === 0) {
          try {
            teams = await user.listTeams();
          } catch (teamsError) {
            console.error("[PreviewLandingPage] Failed to fetch teams", teamsError);
          }
        }
        // Try to fetch connected accounts if we didn't get them earlier
        if (!githubAccount && !gitlabAccount && !bitbucketAccount) {
          try {
            const [github, gitlab, bitbucket] = await Promise.all([
              user.getConnectedAccount("github"),
              user.getConnectedAccount("gitlab"),
              user.getConnectedAccount("bitbucket"),
            ]);
            githubAccount = github;
            gitlabAccount = gitlab;
            bitbucketAccount = bitbucket;
          } catch (accountsError) {
            console.error("[PreviewLandingPage] Failed to fetch connected accounts", accountsError);
          }
        }
      }
    } catch (error) {
      console.error("[PreviewLandingPage] Failed to create fresh session", error);
    }
  }

  // If we still don't have an access token, show the unauthenticated view
  // This allows the user to sign in again rather than seeing a crash
  if (!accessToken) {
    console.error("[PreviewLandingPage] No access token available after retry, showing unauthenticated view");
    return renderUnauthenticatedView();
  }

  // Check if user authenticated with GitLab or Bitbucket but not GitHub
  // These providers are still in beta, so show waitlist in the repo selection box
  const hasGitHub = !!githubAccount;
  const hasGitLab = !!gitlabAccount;
  const hasBitbucket = !!bitbucketAccount;

  const waitlistProviders: ("gitlab" | "bitbucket")[] = !hasGitHub
    ? [
        ...(hasGitLab ? (["gitlab"] as const) : []),
        ...(hasBitbucket ? (["bitbucket"] as const) : []),
      ]
    : [];

  // Persist waitlist status to server metadata (non-blocking)
  if (waitlistProviders.length > 0) {
    const serverMetadata = user.serverMetadata as Record<string, unknown> | null;
    const existingWaitlist = serverMetadata?.previewWaitlist as string[] | undefined;
    // Only update if waitlist providers changed (compare sorted arrays)
    const existingSorted = existingWaitlist?.slice().sort().join(",") ?? "";
    const newSorted = waitlistProviders.slice().sort().join(",");
    if (existingSorted !== newSorted) {
      waitUntil(
        user.update({
          serverMetadata: {
            ...serverMetadata,
            previewWaitlist: waitlistProviders,
            // Only set joinedAt on first registration
            ...(!existingWaitlist && {
              previewWaitlistJoinedAt: new Date().toISOString(),
            }),
          },
        })
      );
    }
  }

  const searchTeam = (() => {
    if (!resolvedSearch) {
      return null;
    }
    const value = resolvedSearch.team;
    if (Array.isArray(value)) {
      return value[0] ?? null;
    }
    return value ?? null;
  })();

  const popupComplete = (() => {
    const value = resolvedSearch?.popup_complete;
    if (Array.isArray(value)) {
      return value[0] === "true";
    }
    return value === "true";
  })();

  const selectedTeam =
    teams.find((team) => getTeamSlugOrId(team) === searchTeam) ?? teams[0];
  const selectedTeamSlugOrId = selectedTeam ? getTeamSlugOrId(selectedTeam) : "";
  const teamOptions: TeamOption[] = teams.map((team) => ({
    slugOrId: getTeamSlugOrId(team),
    displayName: getTeamDisplayName(team),
  }));

  const convex = getConvex({ accessToken });

  const paywallProductId = "preview-pro";
  // Item ID for checking team subscription (must match backend in preview_quota_actions.ts)
  const PREVIEW_SUBSCRIPTION_ITEM_ID = "preview-team-subscription";

  let paywall: PreviewPaywallState | null = null;
  try {
    const quotaInfo = await convex.query(api.preview_quota.getQuotaInfo, {
      teamSlugOrId: selectedTeamSlugOrId,
    });

    let hasPaid = false;
    let paymentCheckFailed = false;
    try {
      // Check team-level subscription using Stack Auth's team.getItem() API
      // Reference: Stack Auth API - GET /payments/items/{customer_type}/{customer_id}/{item_id}
      // Returns: { id, display_name, quantity } where quantity can be negative
      if (selectedTeam) {
        const item = await selectedTeam.getItem(PREVIEW_SUBSCRIPTION_ITEM_ID);
        console.log("[PreviewLandingPage] getItem response:", {
          teamSlugOrId: selectedTeamSlugOrId,
          itemId: PREVIEW_SUBSCRIPTION_ITEM_ID,
          item,
        });
        // SDK may return quantity or nonNegativeQuantity depending on version
        const quantity = (item as { quantity?: number; nonNegativeQuantity?: number }).quantity
          ?? (item as { nonNegativeQuantity?: number }).nonNegativeQuantity
          ?? 0;
        hasPaid = quantity > 0;
      }
    } catch (error) {
      paymentCheckFailed = true;
      console.error("[PreviewLandingPage] Failed to check team subscription", {
        error,
        teamSlugOrId: selectedTeamSlugOrId,
        itemId: PREVIEW_SUBSCRIPTION_ITEM_ID,
      });
    }

    paywall = {
      isBlocked:
        !paymentCheckFailed &&
        !hasPaid &&
        quotaInfo.remainingRuns <= 0,
      hasPaid,
      usedRuns: quotaInfo.usedRuns,
      freeLimit: quotaInfo.freeLimit,
      productId: paywallProductId,
    };
  } catch (error) {
    console.error("[PreviewLandingPage] Failed to load preview quota info", {
      error,
      teamSlugOrId: selectedTeamSlugOrId,
    });
  }

  const [providerConnectionsByTeamEntries, previewConfigs] = await Promise.all([
    Promise.all(
      teams.map(async (team) => {
        const teamSlugOrId = getTeamSlugOrId(team);
        try {
          const connections = await convex.query(api.github.listProviderConnections, {
            teamSlugOrId,
          });
          const serialized = serializeProviderConnections(connections);
          return [teamSlugOrId, serialized];
        } catch (error) {
          // This can happen for new users before webhook syncs membership to Convex.
          // Return empty connections for this team - it will populate on next page load.
          console.error("[PreviewLandingPage] Failed to load provider connections", {
            teamSlugOrId,
            error,
          });
          return [teamSlugOrId, []];
        }
      }),
    ),
    Promise.all(
      teams.map(async (team) => {
        const teamSlugOrId = getTeamSlugOrId(team);
        try {
          const configs = await convex.query(api.previewConfigs.listByTeam, {
            teamSlugOrId,
          });
          return configs.map(
            (config): PreviewConfigListItem => ({
              id: config._id,
              repoFullName: config.repoFullName,
              environmentId: config.environmentId ?? null,
              repoInstallationId: config.repoInstallationId ?? null,
              repoDefaultBranch: config.repoDefaultBranch ?? null,
              status: config.status ?? "active",
              lastRunAt: config.lastRunAt ?? null,
              teamSlugOrId,
              teamName: getTeamDisplayName(team),
            })
          );
        } catch (error) {
          // This can happen for new users before webhook syncs membership to Convex.
          // Return empty configs for this team - it will populate on next page load.
          console.error("[PreviewLandingPage] Failed to load preview configs", {
            teamSlugOrId,
            error,
          });
          return [];
        }
      })
    ).then((results) => results.flat()),
  ]);
  const providerConnectionsByTeam = Object.fromEntries(
    providerConnectionsByTeamEntries,
  );

  return (
    <div className="relative isolate min-h-dvh bg-[#05050a] text-white flex justify-center">
      <svg
        className="absolute inset-0 -z-10 w-full h-full -mx-8 sm:mx-0"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 832 252"
        fill="none"
        preserveAspectRatio="none"
      >
        <ellipse className="sm:hidden" cx="446" cy="96" rx="500" ry="126" fill="url(#paint0_radial_preview_2_sm)" />
        <ellipse className="hidden sm:block" cx="446" cy="96" rx="416" ry="126" fill="url(#paint0_radial_preview_2)" />
        <defs>
          <radialGradient
            id="paint0_radial_preview_2_sm"
            cx="0"
            cy="0"
            r="1"
            gradientUnits="userSpaceOnUse"
            gradientTransform="translate(446 96) scale(500 126)"
          >
            <stop stopColor="rgba(4,120,255,0.25)" />
            <stop offset="1" stopColor="rgba(4,120,255,0)" />
          </radialGradient>
          <radialGradient
            id="paint0_radial_preview_2"
            cx="0"
            cy="0"
            r="1"
            gradientUnits="userSpaceOnUse"
            gradientTransform="translate(446 96) scale(416 126)"
          >
            <stop stopColor="rgba(4,120,255,0.25)" />
            <stop offset="1" stopColor="rgba(4,120,255,0)" />
          </radialGradient>
        </defs>
      </svg>

      <PreviewDashboard
        selectedTeamSlugOrId={selectedTeamSlugOrId}
        teamOptions={teamOptions}
        providerConnectionsByTeam={providerConnectionsByTeam}
        isAuthenticated={true}
        previewConfigs={previewConfigs}
        popupComplete={popupComplete}
        waitlistProviders={waitlistProviders}
        waitlistEmail={user.primaryEmail}
        paywall={paywall}
      />
    </div>
  );
}
