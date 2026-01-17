import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { stackServerApp } from "@/lib/utils/stack";
import { getConvex } from "@/lib/utils/get-convex";
import { api } from "@cmux/convex/api";
import {
  getTeamDisplayName,
  getTeamSlugOrId,
  type StackTeam,
} from "@/lib/team-utils";
import { PreviewSubscriptionClient } from "@/components/preview/preview-subscription-client";

export const metadata: Metadata = {
  title: "Subscribe to cmux Preview",
  description:
    "Unlock unlimited screenshot previews for your GitHub PRs with cmux Preview subscription.",
  openGraph: {
    title: "Subscribe to cmux Preview",
    description:
      "Unlock unlimited screenshot previews for your GitHub PRs",
    type: "website",
  },
};

export const dynamic = "force-dynamic";

// Item ID for checking team subscription (must match backend in preview_quota_actions.ts)
const PREVIEW_SUBSCRIPTION_ITEM_ID = "preview-team-subscription";

type PageProps = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

export default async function PreviewSubscriptionPage({ searchParams }: PageProps) {
  const user = await stackServerApp.getUser();
  const resolvedSearch = await searchParams;

  // If user is not authenticated, redirect to sign-in
  if (!user) {
    const signInUrl = `/handler/sign-in?after_auth_return_to=${encodeURIComponent("/preview/subscription")}`;
    return redirect(signInUrl);
  }

  const [auth, teamsResult] = await Promise.all([
    user.getAuthJson(),
    user.listTeams(),
  ]);
  const teams: StackTeam[] = teamsResult;
  const { accessToken } = auth;

  if (!accessToken) {
    throw new Error("Missing Stack access token");
  }

  // Get selected team from search params
  const searchTeam = (() => {
    if (!resolvedSearch) return null;
    const value = resolvedSearch.team;
    if (Array.isArray(value)) return value[0] ?? null;
    return value ?? null;
  })();

  const selectedTeam =
    teams.find((team) => getTeamSlugOrId(team) === searchTeam) ?? teams[0];
  const selectedTeamSlugOrId = selectedTeam ? getTeamSlugOrId(selectedTeam) : "";

  // Get user's current preview usage
  const convex = getConvex({ accessToken });
  let usedRuns = 0;
  let remainingRuns = 10;
  let freeLimit = 10;

  if (selectedTeamSlugOrId) {
    try {
      const quotaInfo = await convex.query(api.preview_quota.getQuotaInfo, {
        teamSlugOrId: selectedTeamSlugOrId,
      });
      usedRuns = quotaInfo.usedRuns;
      remainingRuns = quotaInfo.remainingRuns;
      freeLimit = quotaInfo.freeLimit;
    } catch (error) {
      console.error("[PreviewSubscriptionPage] Failed to get quota info", { error });
    }
  }

  // Check subscription status for each team using Stack Auth
  // Reference: Stack Auth API - GET /payments/items/{customer_type}/{customer_id}/{item_id}
  // Returns: { id, display_name, quantity } where quantity can be negative
  const teamSubscriptionStatus: Record<string, boolean> = {};
  await Promise.all(
    teams.map(async (team) => {
      const teamSlugOrId = getTeamSlugOrId(team);
      try {
        const item = await team.getItem(PREVIEW_SUBSCRIPTION_ITEM_ID);
        console.log("[PreviewSubscriptionPage] getItem response:", {
          teamSlugOrId,
          itemId: PREVIEW_SUBSCRIPTION_ITEM_ID,
          item,
        });
        // SDK may return quantity or nonNegativeQuantity depending on version
        const quantity = (item as { quantity?: number; nonNegativeQuantity?: number }).quantity
          ?? (item as { nonNegativeQuantity?: number }).nonNegativeQuantity
          ?? 0;
        teamSubscriptionStatus[teamSlugOrId] = quantity > 0;
      } catch (error) {
        console.error("[PreviewSubscriptionPage] Failed to check team subscription", {
          teamSlugOrId,
          error,
        });
        teamSubscriptionStatus[teamSlugOrId] = false;
      }
    })
  );

  const teamOptions = teams.map((team) => ({
    slugOrId: getTeamSlugOrId(team),
    displayName: getTeamDisplayName(team),
  }));

  return (
    <div className="relative isolate min-h-dvh bg-[#05050a] text-white flex justify-center">
      <svg
        className="absolute inset-0 -z-10 w-full h-full -mx-8 sm:mx-0"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 832 252"
        fill="none"
        preserveAspectRatio="none"
      >
        <ellipse
          className="sm:hidden"
          cx="446"
          cy="96"
          rx="500"
          ry="126"
          fill="url(#paint0_radial_subscription_sm)"
        />
        <ellipse
          className="hidden sm:block"
          cx="446"
          cy="96"
          rx="416"
          ry="126"
          fill="url(#paint0_radial_subscription)"
        />
        <defs>
          <radialGradient
            id="paint0_radial_subscription_sm"
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
            id="paint0_radial_subscription"
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

      <PreviewSubscriptionClient
        selectedTeamSlugOrId={selectedTeamSlugOrId}
        teamOptions={teamOptions}
        teamSubscriptionStatus={teamSubscriptionStatus}
        usedRuns={usedRuns}
        remainingRuns={remainingRuns}
        freeLimit={freeLimit}
        userEmail={user.primaryEmail}
      />
    </div>
  );
}
