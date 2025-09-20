import { CreateTeamDialog, type CreateTeamFormValues } from "@/components/CreateTeamDialog";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { isElectron } from "@/lib/electron";
import { stackClientApp } from "@/lib/stack";
import { setLastTeamSlugOrId } from "@/lib/lastTeam";
import { api } from "@cmux/convex/api";
import { Skeleton } from "@heroui/react";
import { useStackApp, useUser, type Team } from "@stackframe/react";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery as useConvexQuery } from "convex/react";
import React from "react";

export const Route = createFileRoute("/_layout/team-picker")({
  component: TeamPicker,
});

function normalizeSlugValue(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+/, "")
    .replace(/-+$/, "")
    .slice(0, 48);
}

function TeamPicker() {
  const app = useStackApp();
  const user = useUser({ or: "return-null" });
  const navigate = useNavigate();
  const accountSettingsUrl = app.urls.accountSettings;
  // Call the Stack teams hook at the top level (no memo to satisfy hook rules)
  const teams: Team[] = user?.useTeams() ?? [];

  // Convex helpers to immediately reflect team creation/membership locally
  const upsertTeamPublic = useMutation(api.stack.upsertTeamPublic);
  const ensureMembershipPublic = useMutation(api.stack.ensureMembershipPublic);
  const setTeamSlug = useMutation(api.teams.setSlug);

  const [isCreateTeamDialogOpen, setIsCreateTeamDialogOpen] =
    React.useState(false);
  const [isCreatingTeam, setIsCreatingTeam] = React.useState(false);
  const [createTeamError, setCreateTeamError] = React.useState<string | null>(
    null
  );

  const getClientSlug = (meta: unknown): string | undefined => {
    if (meta && typeof meta === "object" && meta !== null) {
      const maybe = meta as Record<string, unknown>;
      const val = maybe.slug;
      if (typeof val === "string" && val.trim().length > 0) return val;
    }
    return undefined;
  };

  const redirectToAccountSettings = React.useCallback(async () => {
    await stackClientApp.redirectToAccountSettings?.().catch(() => {
      void navigate({ to: accountSettingsUrl });
    });
  }, [accountSettingsUrl, navigate]);

  const handleOpenCreateTeam = React.useCallback(() => {
    if (!user) {
      void redirectToAccountSettings();
      return;
    }
    setCreateTeamError(null);
    setIsCreateTeamDialogOpen(true);
  }, [redirectToAccountSettings, user]);

  const handleCreateTeam = React.useCallback(
    async ({ name, slug, invites }: CreateTeamFormValues) => {
      if (!user) {
        await redirectToAccountSettings();
        return;
      }

      const trimmedName = name.trim();
      const normalizedSlug = normalizeSlugValue(slug);

      setIsCreatingTeam(true);
      setCreateTeamError(null);

      try {
        const newTeam = await user.createTeam({
          displayName: trimmedName,
        });

        try {
          await setTeamSlug({ teamSlugOrId: newTeam.id, slug: normalizedSlug });
        } catch (slugError) {
          await newTeam.delete().catch((deleteError) => {
            console.error("Failed to delete team after slug error", deleteError);
          });
          throw slugError;
        }

        const existingMetadata =
          typeof newTeam.clientMetadata === "object" &&
          newTeam.clientMetadata !== null &&
          !Array.isArray(newTeam.clientMetadata)
            ? (newTeam.clientMetadata as Record<string, unknown>)
            : {};

        try {
          await newTeam.update({
            clientMetadata: {
              ...existingMetadata,
              slug: normalizedSlug,
            },
          });
        } catch (metadataError) {
          console.warn(
            "Failed to update team metadata with slug",
            metadataError
          );
        }

        await upsertTeamPublic({
          id: newTeam.id,
          displayName: newTeam.displayName,
          profileImageUrl: newTeam.profileImageUrl ?? undefined,
          createdAtMillis: Date.now(),
        });

        await ensureMembershipPublic({ teamId: newTeam.id, userId: user.id });

        for (const email of invites) {
          try {
            await newTeam.inviteUser({ email });
          } catch (inviteError) {
            console.error("Failed to invite", email, inviteError);
          }
        }

        await user.setSelectedTeam(newTeam);
        const teamSlugOrId = normalizedSlug || newTeam.id;
        setLastTeamSlugOrId(teamSlugOrId);
        setIsCreateTeamDialogOpen(false);
        await navigate({
          to: "/$teamSlugOrId/dashboard",
          params: { teamSlugOrId },
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        setCreateTeamError(message || "Failed to create team");
        console.error("Failed to create team", error);
      } finally {
        setIsCreatingTeam(false);
      }
    },
    [
      ensureMembershipPublic,
      navigate,
      redirectToAccountSettings,
      setTeamSlug,
      upsertTeamPublic,
      user,
    ]
  );

  return (
    <>
      <CreateTeamDialog
        open={isCreateTeamDialogOpen}
        onOpenChange={(open) => {
          if (!open && isCreatingTeam) {
            return;
          }
          setIsCreateTeamDialogOpen(open);
          if (!open) {
            setCreateTeamError(null);
          }
        }}
        onSubmit={handleCreateTeam}
        isSubmitting={isCreatingTeam}
        error={createTeamError}
      />
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
                  <Button onClick={handleOpenCreateTeam}>
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
                      onClick={handleOpenCreateTeam}
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
    </>
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
