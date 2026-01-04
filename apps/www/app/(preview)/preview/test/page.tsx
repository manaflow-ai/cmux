import type { Metadata } from "next";
import { redirect } from "next/navigation";
import { stackServerApp } from "@/lib/utils/stack";
import {
  getTeamDisplayName,
  getTeamSlugOrId,
  type StackTeam,
} from "@/lib/team-utils";
import { PreviewTestDashboard } from "@/components/preview/preview-test-dashboard";

export const metadata: Metadata = {
  title: "Preview.new Testing",
  description: "Test preview.new jobs without GitHub integration",
};

export const dynamic = "force-dynamic";

type PageProps = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

type TeamOption = {
  slugOrId: string;
  displayName: string;
};

export default async function PreviewTestPage({ searchParams }: PageProps) {
  const user = await stackServerApp.getUser();
  const resolvedSearch = await searchParams;

  if (!user) {
    const signInUrl = `/handler/sign-in?after_auth_return_to=${encodeURIComponent("/preview/test")}`;
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

  const selectedTeam =
    teams.find((team) => getTeamSlugOrId(team) === searchTeam) ?? teams[0];
  const selectedTeamSlugOrId = selectedTeam ? getTeamSlugOrId(selectedTeam) : "";
  const teamOptions: TeamOption[] = teams.map((team) => ({
    slugOrId: getTeamSlugOrId(team),
    displayName: getTeamDisplayName(team),
  }));

  return (
    <div className="relative isolate min-h-dvh bg-[#05050a] text-white">
      <div className="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        <PreviewTestDashboard
          selectedTeamSlugOrId={selectedTeamSlugOrId}
          teamOptions={teamOptions}
        />
      </div>
    </div>
  );
}
