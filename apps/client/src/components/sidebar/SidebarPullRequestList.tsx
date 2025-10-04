import { VSCodeIcon } from "@/components/icons/VSCodeIcon";
import { GitHubIcon } from "@/components/icons/github";
import { api } from "@cmux/convex/api";
import { Link } from "@tanstack/react-router";
import { useQuery as useConvexQuery } from "convex/react";
import {
  ExternalLink,
  GitMerge,
  GitPullRequest,
  GitPullRequestClosed,
  GitPullRequestDraft,
} from "lucide-react";
import { useMemo, useState, type ComponentType, type MouseEvent } from "react";
import { SidebarListItem } from "./SidebarListItem";
import { SIDEBAR_PRS_DEFAULT_LIMIT } from "./const";

type Props = {
  teamSlugOrId: string;
  limit?: number;
};

export function SidebarPullRequestList({
  teamSlugOrId,
  limit = SIDEBAR_PRS_DEFAULT_LIMIT,
}: Props) {
  const prs = useConvexQuery(api.github_prs.listPullRequests, {
    teamSlugOrId,
    state: "open",
    limit,
  });

  const [expanded, setExpanded] = useState<Record<string, boolean>>({});

  const list = useMemo(() => prs ?? [], [prs]);

  console.log("[SidebarPullRequestList]", {
    teamSlugOrId,
    prsUndefined: prs === undefined,
    prsLength: prs?.length,
    prs,
  });

  if (prs === undefined) {
    return (
      <ul className="flex flex-col gap-px" aria-label="Loading pull requests">
        {Array.from({ length: limit }).map((_, index) => (
          <li key={index} className="px-2 py-1.5">
            <div className="h-3 rounded bg-neutral-200 dark:bg-neutral-800 animate-pulse" />
          </li>
        ))}
      </ul>
    );
  }

  if (list.length === 0) {
    return (
      <p className="mt-1 px-3 py-2 text-xs text-neutral-500 dark:text-neutral-400 select-none">
        No pull requests
      </p>
    );
  }

  return (
    <ul className="flex flex-col gap-px">
      {list.map((pr) => {
        const [owner = "", repo = ""] = pr.repoFullName?.split("/", 2) ?? [
          "",
          "",
        ];
        const key = `${pr.repoFullName}#${pr.number}`;
        const isExpanded = expanded[key] ?? false;
        const branchLabel = pr.headRef;

        const secondaryParts = [
          branchLabel,
          `${pr.repoFullName}#${pr.number}`,
          pr.authorLogin,
        ]
          .filter(Boolean)
          .map(String);
        const secondary = secondaryParts.join(" • ");
        const leadingIcon = pr.merged ? (
          <GitMerge className="w-3 h-3 text-purple-500" />
        ) : pr.state === "closed" ? (
          <GitPullRequestClosed className="w-3 h-3 text-red-500" />
        ) : pr.draft ? (
          <GitPullRequestDraft className="w-3 h-3 text-neutral-500" />
        ) : (
          <GitPullRequest className="w-3 h-3 text-[#1f883d] dark:text-[#238636]" />
        );

        const actionButtons: ReadonlyArray<{
          key: "vscode" | "preview" | "github";
          label: string;
          icon: ComponentType<{ className?: string; "aria-hidden"?: boolean }>;
        }> = [
          {
            key: "vscode",
            label: "VS Code",
            icon: VSCodeIcon,
          },
          {
            key: "preview",
            label: "Preview",
            icon: ExternalLink,
          },
          {
            key: "github",
            label: "GitHub",
            icon: GitHubIcon,
          },
        ];

        const handleToggle = (
          _event?: MouseEvent<HTMLButtonElement | HTMLAnchorElement>
        ) => {
          setExpanded((prev) => ({
            ...prev,
            [key]: !isExpanded,
          }));
        };

        return (
          <li key={key} className="rounded-md select-none">
            <Link
              to="/$teamSlugOrId/prs-only/$owner/$repo/$number"
              params={{
                teamSlugOrId,
                owner,
                repo,
                number: String(pr.number),
              }}
              className="group block"
              onClick={(event) => {
                if (
                  event.defaultPrevented ||
                  event.metaKey ||
                  event.ctrlKey ||
                  event.shiftKey ||
                  event.altKey
                ) {
                  return;
                }
                handleToggle(event);
              }}
            >
              <SidebarListItem
                paddingLeft={10}
                toggle={{
                  expanded: isExpanded,
                  onToggle: handleToggle,
                  visible: true,
                }}
                title={pr.title}
                titleClassName="text-[13px] text-neutral-950 dark:text-neutral-100"
                secondary={secondary || undefined}
                meta={leadingIcon}
              />
            </Link>
            {isExpanded ? (
              <div className="mt-px flex flex-col" role="group">
                {actionButtons.map((action) => {
                  const Icon = action.icon;
                  return (
                    <button
                      key={action.key}
                      type="button"
                      onClick={(event) => {
                        event.preventDefault();
                        event.stopPropagation();
                      }}
                      className="mt-px flex w-full items-center rounded-md pr-2 py-1 text-xs transition-colors hover:bg-neutral-200/45 dark:hover:bg-neutral-800/45 cursor-default"
                      style={{ paddingLeft: "32px" }}
                    >
                      <Icon
                        className="mr-2 h-3 w-3 text-neutral-400 grayscale opacity-60"
                        aria-hidden
                      />
                      <span className="text-neutral-600 dark:text-neutral-400">
                        {action.label}
                      </span>
                    </button>
                  );
                })}
              </div>
            ) : null}
          </li>
        );
      })}
    </ul>
  );
}

export default SidebarPullRequestList;
