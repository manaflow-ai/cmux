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

export default async function PreviewLandingPage({ searchParams }: PageProps) {
  const user = await stackServerApp.getUser();
  const resolvedSearch = await searchParams;

  if (!user) {
    return (
      <div className="relative isolate min-h-dvh bg-[#05050a] text-white flex justify-center">
        <svg
          className="absolute inset-0 -z-10 w-full h-full -mx-8 sm:mx-0"
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 832 252"
          fill="none"
          preserveAspectRatio="none"
        >
          <ellipse className="sm:hidden" cx="446" cy="96" rx="500" ry="126" fill="url(#paint0_radial_preview_1_sm)" />
          <ellipse className="hidden sm:block" cx="446" cy="96" rx="416" ry="126" fill="url(#paint0_radial_preview_1)" />
          <defs>
            <radialGradient
              id="paint0_radial_preview_1_sm"
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
              id="paint0_radial_preview_1"
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

  const [auth, teamsResult, githubAccount, gitlabAccount, bitbucketAccount] = await Promise.all([
    user.getAuthJson(),
    user.listTeams(),
    user.getConnectedAccount("github"),
    user.getConnectedAccount("gitlab"),
    user.getConnectedAccount("bitbucket"),
  ]);
  const teams: StackTeam[] = teamsResult;
  const { accessToken } = auth;

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

  if (!accessToken) {
    throw new Error("Missing Stack access token");
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
        const connections = await convex.query(api.github.listProviderConnections, {
          teamSlugOrId,
        });
        const serialized = serializeProviderConnections(connections);
        return [teamSlugOrId, serialized];
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
