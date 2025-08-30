import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { stackClientApp } from "@/stack";
import { api } from "@cmux/convex/api";
import { Skeleton } from "@heroui/react";
import { useStackApp, useUser, type Team } from "@stackframe/react";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useQuery as useConvexQuery, useMutation } from "convex/react";

export const Route = createFileRoute("/_layout/team-picker")({
  component: TeamPicker,
});

function TeamPicker() {
  const app = useStackApp();
  const user = useUser({ or: "return-null" });
  const navigate = useNavigate();
  // Call the Stack teams hook at the top level (no memo to satisfy hook rules)
  const teams: Team[] = user?.useTeams() ?? [];

  // Convex helpers to immediately reflect team creation/membership locally
  const upsertTeamPublic = useMutation(api.stack.upsertTeamPublic);
  const ensureMembershipPublic = useMutation(api.stack.ensureMembershipPublic);

  const getClientSlug = (meta: unknown): string | undefined => {
    if (meta && typeof meta === "object" && meta !== null) {
      const maybe = meta as Record<string, unknown>;
      const val = maybe.slug;
      if (typeof val === "string" && val.trim().length > 0) return val;
    }
    return undefined;
  };

  const handleCreateTeam = async () => {
    if (!user) {
      await stackClientApp.redirectToAccountSettings?.().catch(() => {
        const url = app.urls.accountSettings;
        void navigate({ to: url });
      });
      return;
    }

    const displayName = window.prompt("Name your new team");
    if (!displayName || !displayName.trim()) return;

    try {
      const newTeam = await user.createTeam({
        displayName: displayName.trim(),
      });

      // Ensure Convex mirrors the new team and membership immediately (webhooks may lag)
      await upsertTeamPublic({
        id: newTeam.id,
        displayName: newTeam.displayName,
        profileImageUrl: newTeam.profileImageUrl ?? undefined,
        createdAtMillis: Date.now(),
      });
      await ensureMembershipPublic({ teamId: newTeam.id, userId: user.id });

      // Invite onboarding
      const inviteInput = window.prompt(
        "Invite teammates (comma-separated emails), or leave blank"
      );
      if (inviteInput && inviteInput.trim()) {
        const emails = inviteInput
          .split(",")
          .map((e) => e.trim())
          .filter((e) => e.length > 0);
        for (const email of emails) {
          try {
            await newTeam.inviteUser({ email });
          } catch (e) {
            console.error("Failed to invite", email, e);
          }
        }
      }

      // Navigate into the new team's dashboard
      const teamSlugOrId =
        (newTeam.clientMetadata &&
        typeof newTeam.clientMetadata === "object" &&
        newTeam.clientMetadata !== null &&
        (newTeam.clientMetadata as Record<string, unknown>).slug &&
        typeof (newTeam.clientMetadata as Record<string, unknown>).slug ===
          "string"
          ? ((newTeam.clientMetadata as Record<string, unknown>).slug as string)
          : undefined) ?? newTeam.id;

      await user.setSelectedTeam(newTeam);
      await navigate({
        to: "/$teamSlugOrId/dashboard",
        params: { teamSlugOrId },
      });
    } catch (err) {
      console.error(
        "Failed to create team via Stack, redirecting to settings",
        err
      );
      await stackClientApp.redirectToAccountSettings?.().catch(() => {
        const url = app.urls.accountSettings;
        void navigate({ to: url });
      });
    }
  };

  // Do not auto-redirect when there is exactly one team.

  return (
    <div className="min-h-dvh w-full bg-neutral-50 dark:bg-neutral-950 flex items-center justify-center p-6">
      <div className="mx-auto w-full max-w-3xl">
        <Card className="border-neutral-200 dark:border-neutral-800 bg-white/70 dark:bg-neutral-900/70 backdrop-blur">
          <CardHeader>
            <CardTitle className="text-neutral-900 dark:text-neutral-50">
              Choose a team
            </CardTitle>
            <CardDescription className="text-neutral-600 dark:text-neutral-400">
              Pick a team to continue. You can switch teams anytime.
            </CardDescription>
          </CardHeader>
          <CardContent>
            {teams.length === 0 ? (
              <div className="flex flex-col items-center justify-center gap-4 py-12">
                <div className="text-center">
                  <p className="text-neutral-800 dark:text-neutral-200 text-lg font-medium">
                    You’re not in any teams yet
                  </p>
                  <p className="text-neutral-600 dark:text-neutral-400 mt-1">
                    Create a team to get started.
                  </p>
                </div>
                <Button onClick={handleCreateTeam} className="">
                  Create a team
                </Button>
              </div>
            ) : (
              <div className="flex flex-col gap-6">
                <ul className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  {teams.map((team) => (
                    <TeamItem
                      key={team.id}
                      team={team}
                      getClientSlug={getClientSlug}
                    />
                  ))}
                </ul>

                <div className="flex items-center justify-end pt-2">
                  <Button
                    variant="ghost"
                    onClick={handleCreateTeam}
                    className="text-neutral-700 dark:text-neutral-300"
                  >
                    Create new team
                  </Button>
                </div>
              </div>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

interface TeamItemProps {
  team: Team;
  getClientSlug: (meta: unknown) => string | undefined;
}

function TeamItem({ team, getClientSlug }: TeamItemProps) {
  const teamInfo = useConvexQuery(api.teams.get, { teamSlugOrId: team.id });
  const slug = teamInfo?.slug || getClientSlug(team.clientMetadata);

  return (
    <li>
      <Link
        to="/$teamSlugOrId/dashboard"
        params={{ teamSlugOrId: slug! }}
        disabled={!teamInfo}
        className={
          "group flex w-full text-left rounded-xl border transition-all focus:outline-none border-neutral-200 hover:border-neutral-300 dark:border-neutral-800 dark:hover:border-neutral-700 bg-white dark:bg-neutral-900/80 disabled:border-neutral-200 dark:disabled:border-neutral-800 p-4"
        }
      >
        <div className="flex items-center gap-3">
          <div
            className={
              "flex h-10 w-10 items-center justify-center rounded-full bg-neutral-100 text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200 ring-1 ring-inset ring-neutral-200 dark:ring-neutral-700"
            }
            aria-hidden
          >
            {team.displayName?.charAt(0) ?? "T"}
          </div>
          <div className="flex-1 overflow-hidden">
            <div className="truncate text-neutral-900 dark:text-neutral-50 font-medium">
              {team.displayName}
            </div>
            <div className="truncate text-sm text-neutral-500 dark:text-neutral-400">
              <Skeleton isLoaded={!!teamInfo} className="rounded">
                {slug || "Loading..."}
              </Skeleton>
            </div>
          </div>
        </div>
      </Link>
    </li>
  );
}
