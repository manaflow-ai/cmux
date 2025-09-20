import { CreateTeamDialog, type CreateTeamFormValues } from "@/components/team/CreateTeamDialog";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { stackClientApp } from "@/lib/stack";
import { isElectron } from "@/lib/electron";
import { api } from "@cmux/convex/api";
import { postApiTeams } from "@cmux/www-openapi-client";
import { Skeleton } from "@heroui/react";
import { useStackApp, useUser, type Team } from "@stackframe/react";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { setLastTeamSlugOrId } from "@/lib/lastTeam";
import { useQuery as useConvexQuery, useMutation } from "convex/react";
import { useCallback, useState } from "react";
import type React from "react";

export const Route = createFileRoute("/_layout/team-picker")({
  component: TeamPicker,
});

function TeamPicker() {
  const app = useStackApp();
  const user = useUser({ or: "return-null" });
  const navigate = useNavigate();
  // Call the Stack teams hook at the top level (no memo to satisfy hook rules)
  const teams: Team[] = user?.useTeams() ?? [];
  const [createDialogOpen, setCreateDialogOpen] = useState(false);

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

  const openCreateTeamDialog = useCallback(() => {
    if (!user) {
      void stackClientApp.redirectToAccountSettings?.().catch(() => {
        const url = app.urls.accountSettings;
        void navigate({ to: url });
      });
      return;
    }
    setCreateDialogOpen(true);
  }, [app.urls.accountSettings, navigate, user]);

  const handleCreateTeamSubmit = useCallback(
    async (values: CreateTeamFormValues) => {
      if (!user) {
        await stackClientApp.redirectToAccountSettings?.().catch(() => {
          const url = app.urls.accountSettings;
          void navigate({ to: url });
        });
        throw new Error("You must be signed in to create a team.");
      }

      try {
        const { data } = await postApiTeams({
          body: {
            displayName: values.displayName,
            slug: values.slug,
            inviteEmails:
              values.inviteEmails.length > 0 ? values.inviteEmails : undefined,
          },
          throwOnError: true,
        });

        await upsertTeamPublic({
          id: data.teamId,
          displayName: data.displayName,
          profileImageUrl: undefined,
          createdAtMillis: Date.now(),
        });
        await ensureMembershipPublic({ teamId: data.teamId, userId: user.id });

        const teamSlugOrId = data.slug ?? data.teamId;

        let stackTeam: Team | null = null;
        const timeoutAt = Date.now() + 15_000;
        while (Date.now() < timeoutAt) {
          stackTeam = await user.getTeam(data.teamId);
          if (stackTeam) break;
          await new Promise((resolve) => setTimeout(resolve, 400));
        }
        if (stackTeam) {
          await user.setSelectedTeam(stackTeam);
        }

        setLastTeamSlugOrId(teamSlugOrId);
        await navigate({
          to: "/$teamSlugOrId/dashboard",
          params: { teamSlugOrId },
        });
      } catch (error) {
        const message =
          typeof error === "string"
            ? error
            : error instanceof Error
            ? error.message
            : error &&
              typeof error === "object" &&
              "message" in error &&
              typeof (error as { message?: unknown }).message === "string"
            ? ((error as { message: string }).message)
            : "Failed to create team";
        throw new Error(message);
      }
    },
    [ensureMembershipPublic, navigate, upsertTeamPublic, user, app.urls.accountSettings]
  );

  return (
    <div className="min-h-dvh w-full bg-neutral-50 dark:bg-neutral-950 flex items-center justify-center p-6">
      {isElectron ? (
        <div
          className="fixed top-0 left-0 right-0 h-[24px]"
          style={{ WebkitAppRegion: "drag" } as React.CSSProperties}
        />
      ) : null}
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
                <Button onClick={openCreateTeamDialog} className="">
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
                    onClick={openCreateTeamDialog}
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
      <CreateTeamDialog
        open={createDialogOpen}
        onOpenChange={setCreateDialogOpen}
        onSubmit={handleCreateTeamSubmit}
      />
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
  const teamSlugOrId = slug ?? team.id;

  return (
    <li>
      <Link
        to="/$teamSlugOrId/dashboard"
        params={{ teamSlugOrId }}
        onClick={() => {
          setLastTeamSlugOrId(teamSlugOrId);
        }}
        className={
          "group flex w-full text-left rounded-xl border transition-all focus:outline-none border-neutral-200 hover:border-neutral-300 dark:border-neutral-800 dark:hover:border-neutral-700 bg-white dark:bg-neutral-900/80 disabled:border-neutral-200 dark:disabled:border-neutral-800 p-4"
        }
      >
        <div className="flex items-center gap-3 min-w-0">
          <div
            className={
              "flex h-10 w-10 items-center justify-center rounded-full bg-neutral-100 text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200 ring-1 ring-inset ring-neutral-200 dark:ring-neutral-700"
            }
            aria-hidden
          >
            {team.displayName?.charAt(0) ?? "T"}
          </div>
          <div className="flex-1 overflow-hidden min-w-0">
            <div className="truncate text-neutral-900 dark:text-neutral-50 font-medium">
              {team.displayName}
            </div>
            <div className="text-sm text-neutral-500 dark:text-neutral-400 min-w-0 overflow-hidden">
              <Skeleton isLoaded={!!teamInfo} className="rounded">
                <span className="block truncate">{slug || team.id}</span>
              </Skeleton>
            </div>
          </div>
        </div>
      </Link>
    </li>
  );
}
