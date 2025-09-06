import { Dropdown } from "@/components/ui/dropdown";
import { api } from "@cmux/convex/api";
import type { Doc } from "@cmux/convex/dataModel";
import { ChevronDown, Plus } from "lucide-react";
import { useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery } from "convex/react";
import { useUser, useStackApp } from "@stackframe/react";
import clsx from "clsx";
import * as React from "react";

interface TeamSwitcherProps {
  teamSlugOrId: string;
  className?: string;
  style?: React.CSSProperties;
}

export function TeamSwitcher({ teamSlugOrId, className, style }: TeamSwitcherProps) {
  const navigate = useNavigate();
  const app = useStackApp();
  const user = useUser({ or: "return-null" });
  const memberships = useQuery(api.teams.listTeamMemberships);
  // Convex helpers for create flow (mirrors Stack changes immediately)
  const upsertTeamPublic = useMutation(api.stack.upsertTeamPublic);
  const ensureMembershipPublic = useMutation(api.stack.ensureMembershipPublic);
  const teams: Doc<"teams">[] | undefined = React.useMemo(() => {
    return memberships?.map((m) => m.team).filter(Boolean) as Doc<"teams">[] | undefined;
  }, [memberships]);

  const currentTeam: Doc<"teams"> | undefined = React.useMemo(() => {
    if (!teams) return undefined;
    return (
      teams.find((t) => t.slug === teamSlugOrId) ??
      teams.find((t) => t.teamId === teamSlugOrId)
    );
  }, [teams, teamSlugOrId]);

  const label = React.useMemo(() => {
    if (!currentTeam) return "Choose team";
    return (
      currentTeam.displayName ?? currentTeam.name ?? currentTeam.slug ?? currentTeam.teamId
    );
  }, [currentTeam]);

  // We only render an avatar image when present; no fallback bubble.

  const handleSelect = (team: Doc<"teams">) => {
    const next = team.slug ?? team.teamId;
    void navigate({ to: "/$teamSlugOrId/dashboard", params: { teamSlugOrId: next } });
  };

  const handleCreateTeam = async () => {
    if (!user) {
      await app.redirectToAccountSettings?.().catch(() => {
        // As a fallback, push to account settings URL inside the app
        const url = app.urls.accountSettings;
        void navigate({ to: url });
      });
      return;
    }
    const displayName = window.prompt("Name your new team");
    if (!displayName || !displayName.trim()) return;
    try {
      const newTeam = await user.createTeam({ displayName: displayName.trim() });
      // Mirror to Convex so it appears in DB-backed list
      await upsertTeamPublic({
        id: newTeam.id,
        displayName: newTeam.displayName,
        profileImageUrl: newTeam.profileImageUrl ?? undefined,
        createdAtMillis: Date.now(),
      });
      await ensureMembershipPublic({ teamId: newTeam.id, userId: user.id });
      await user.setSelectedTeam(newTeam);
      const next = newTeam.id; // slug may be set later; navigate by id for reliability
      void navigate({ to: "/$teamSlugOrId/dashboard", params: { teamSlugOrId: next } });
    } catch (err) {
      console.error("Failed to create team via Stack", err);
      await app.redirectToAccountSettings?.().catch(() => {
        const url = app.urls.accountSettings;
        void navigate({ to: url });
      });
    }
  };

  return (
    <Dropdown.Root>
      <Dropdown.Trigger
        aria-label="Switch team"
        className={clsx(
          "flex items-center gap-2 px-1.5 py-1 rounded-md",
          "text-neutral-800 dark:text-neutral-200",
          "hover:bg-neutral-100 dark:hover:bg-neutral-900",
          "min-w-0 max-w-[180px] select-none",
          className
        )}
        style={style}
      >
        {currentTeam?.profileImageUrl ? (
          <img
            src={currentTeam.profileImageUrl}
            alt=""
            className="h-6 w-6 rounded-full ring-1 ring-inset ring-neutral-200 dark:ring-neutral-700 object-cover shrink-0"
          />
        ) : null}
        <span className="truncate text-sm leading-5 font-semibold">{label}</span>
        <ChevronDown className="w-3.5 h-3.5 text-neutral-500 shrink-0" />
      </Dropdown.Trigger>
      <Dropdown.Portal>
        <Dropdown.Positioner sideOffset={8}>
          <Dropdown.Popup className="min-w-[220px]">
            <Dropdown.Arrow />
            {teams && teams.length > 0 ? (
              teams.map((team) => {
                const tLabel = team.displayName ?? team.name ?? team.slug ?? team.teamId;
                const isActive = currentTeam?._id === team._id;
                const hasAvatar = !!team.profileImageUrl;
                return (
                  <Dropdown.Item
                    key={team._id}
                    onClick={() => handleSelect(team)}
                    className={clsx("gap-2", isActive && "text-neutral-400 dark:text-neutral-600")}
                  >
                    {hasAvatar ? (
                      <img
                        src={team.profileImageUrl!}
                        alt=""
                        className="h-5 w-5 rounded-full ring-1 ring-inset ring-neutral-200 dark:ring-neutral-700 object-cover"
                      />
                    ) : null}
                    <span className="truncate font-semibold">{tLabel}</span>
                  </Dropdown.Item>
                );
              })
            ) : (
              <div className="px-4 py-2 text-sm text-neutral-500 dark:text-neutral-400">
                No teams found
              </div>
            )}
            <div className="mx-2 my-1 h-px bg-neutral-200 dark:bg-neutral-800" />
            <Dropdown.Item onClick={handleCreateTeam} className="flex items-center gap-2">
              <Plus className="w-3.5 h-3.5" /> Create team…
            </Dropdown.Item>
            <Dropdown.Item onClick={() => navigate({ to: "/team-picker" })}>
              Manage teams…
            </Dropdown.Item>
          </Dropdown.Popup>
        </Dropdown.Positioner>
      </Dropdown.Portal>
    </Dropdown.Root>
  );
}
