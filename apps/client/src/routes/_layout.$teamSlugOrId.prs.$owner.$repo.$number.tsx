import { RunDiffSection } from "@/components/RunDiffSection";
import { Dropdown } from "@/components/ui/dropdown";
import { diffSmartQueryOptions } from "@/queries/diff-smart";
import { api } from "@cmux/convex/api";
import { convexQuery } from "@convex-dev/react-query";
import { useQuery as useRQ } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery as useConvexQuery } from "convex/react";
import { ExternalLink } from "lucide-react";
import { Suspense, useMemo, useState } from "react";

function refWithOrigin(ref: string) {
  if (ref.startsWith("origin/")) {
    return ref;
  }
  return `origin/${ref}`;
}

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/prs/$owner/$repo/$number"
)({
  component: PRDetails,
  loader: async (opts) => {
    const { teamSlugOrId, owner, repo, number } = opts.params;
    void opts.context.queryClient
      .ensureQueryData(
        convexQuery(api.github_prs.listPullRequests, {
          teamSlugOrId,
          state: "all",
        })
      )
      .then(async (prs) => {
        const key = `${owner}/${repo}`;
        const num = Number(number);
        const target = (prs || []).find(
          (p) => p.repoFullName === key && p.number === num
        );
        if (target?.repoFullName && target.baseRef && target.headRef) {
          void opts.context.queryClient.ensureQueryData(
            diffSmartQueryOptions({
              repoFullName: target.repoFullName,
              baseRef: refWithOrigin(target.baseRef),
              headRef: refWithOrigin(target.headRef),
            })
          );
        }
      });
  },
});

function AdditionsAndDeletions({
  repoFullName,
  ref1,
  ref2,
}: {
  repoFullName: string;
  ref1: string;
  ref2: string;
}) {
  const diffsQuery = useRQ(
    diffSmartQueryOptions({
      repoFullName,
      baseRef: refWithOrigin(ref1),
      headRef: refWithOrigin(ref2),
    })
  );

  const totals = diffsQuery.data
    ? diffsQuery.data.reduce(
        (acc, d) => {
          acc.add += d.additions || 0;
          acc.del += d.deletions || 0;
          return acc;
        },
        { add: 0, del: 0 }
      )
    : undefined;

  return (
    <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0">
      {diffsQuery.isPending ? (
        <>
          <span className="inline-block rounded bg-neutral-200 dark:bg-neutral-800 min-w-[20px] h-[14px] animate-pulse" />
          <span className="inline-block rounded bg-neutral-200 dark:bg-neutral-800 min-w-[20px] h-[14px] animate-pulse" />
        </>
      ) : totals ? (
        <>
          <span className="text-green-600 dark:text-green-400 font-medium select-none">
            +{totals.add}
          </span>
          <span className="text-red-600 dark:text-red-400 font-medium select-none">
            -{totals.del}
          </span>
        </>
      ) : null}
    </div>
  );
}

function PRDetails() {
  const { teamSlugOrId, owner, repo, number } = Route.useParams();
  const prs = useConvexQuery(api.github_prs.listPullRequests, {
    teamSlugOrId,
    state: "all",
  });
  const currentPR = useMemo(() => {
    const key = `${owner}/${repo}`;
    const num = Number(number);
    return (
      (prs || []).find((p) => p.repoFullName === key && p.number === num) ||
      null
    );
  }, [prs, owner, repo, number]);

  // Capture diff controls from the viewer (expand/collapse + totals)
  const [diffControls, setDiffControls] = useState<{
    expandAll: () => void;
    collapseAll: () => void;
    totalAdditions: number;
    totalDeletions: number;
  } | null>(null);

  if (!currentPR) {
    return (
      <div className="h-full w-full flex items-center justify-center text-neutral-500 dark:text-neutral-400">
        PR not found
      </div>
    );
  }

  // GitDiffViewer sticky header offset
  const gitDiffViewerClassNames = {
    fileDiffRow: { button: "top-[96px] md:top-[56px]" },
  } as const;

  return (
    <div className="px-0 py-0">
      {/* Header (styled like TaskDetailHeader) */}
      <div className="bg-white dark:bg-neutral-900 text-neutral-900 dark:text-white px-3.5 sticky top-0 z-50 py-2">
        <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-x-3 gap-y-1">
          <div className="col-start-1 row-start-1 flex items-center gap-2 relative min-w-0">
            <h1
              className="text-sm font-bold truncate min-w-0"
              title={currentPR.title}
            >
              {currentPR.title}
            </h1>
            <Suspense
              fallback={
                <div className="flex items-center gap-2 text-[11px] ml-2 shrink-0" />
              }
            >
              <AdditionsAndDeletions
                repoFullName={currentPR.repoFullName}
                ref1={currentPR.baseRef || ""}
                ref2={currentPR.headRef || ""}
              />
            </Suspense>
          </div>

          <div className="col-start-3 row-start-1 row-span-2 self-center flex items-center gap-2 shrink-0">
            {currentPR.draft ? (
              <span className="text-xs px-2 py-1 rounded-md bg-neutral-200 dark:bg-neutral-800 text-neutral-800 dark:text-neutral-200 select-none">
                Draft
              </span>
            ) : null}
            {currentPR.merged ? (
              <span className="text-xs px-2 py-1 rounded-md bg-purple-200 dark:bg-purple-900/40 text-purple-900 dark:text-purple-200 select-none">
                Merged
              </span>
            ) : currentPR.state === "closed" ? (
              <span className="text-xs px-2 py-1 rounded-md bg-red-200 dark:bg-red-900/40 text-red-900 dark:text-red-200 select-none">
                Closed
              </span>
            ) : (
              <span className="text-xs px-2 py-1 rounded-md bg-green-200 dark:bg-green-900/40 text-green-900 dark:text-green-200 select-none">
                Open
              </span>
            )}
            {currentPR.htmlUrl ? (
              <a
                className="flex items-center gap-1.5 px-3 py-1 bg-neutral-200 dark:bg-neutral-800 text-neutral-900 dark:text-white border border-neutral-300 dark:border-neutral-700 rounded hover:bg-neutral-300 dark:hover:bg-neutral-700 font-medium text-xs select-none whitespace-nowrap"
                href={currentPR.htmlUrl}
                target="_blank"
                rel="noreferrer"
              >
                <ExternalLink className="w-3.5 h-3.5" />
                Open on GitHub
              </a>
            ) : null}
            <Dropdown.Root>
              <Dropdown.Trigger
                className="p-1 text-neutral-400 hover:text-neutral-700 dark:hover:text-white select-none"
                aria-label="More actions"
              >
                ⋯
              </Dropdown.Trigger>
              <Dropdown.Portal>
                <Dropdown.Positioner sideOffset={5}>
                  <Dropdown.Popup>
                    <Dropdown.Arrow />
                    <Dropdown.Item onClick={() => diffControls?.expandAll?.()}>
                      Expand all
                    </Dropdown.Item>
                    <Dropdown.Item
                      onClick={() => diffControls?.collapseAll?.()}
                    >
                      Collapse all
                    </Dropdown.Item>
                  </Dropdown.Popup>
                </Dropdown.Positioner>
              </Dropdown.Portal>
            </Dropdown.Root>
          </div>

          <div className="col-start-1 row-start-2 col-span-2 flex items-center gap-2 text-xs text-neutral-400 min-w-0">
            <span className="font-mono text-neutral-600 dark:text-neutral-300 truncate min-w-0 max-w-full select-none text-[11px]">
              {currentPR.repoFullName}#{currentPR.number} •{" "}
              {currentPR.authorLogin || ""}
            </span>
            <span className="text-neutral-500 dark:text-neutral-600 select-none">
              •
            </span>
            <span className="text-[11px] text-neutral-600 dark:text-neutral-300 select-none">
              {currentPR.headRef || "?"} → {currentPR.baseRef || "?"}
            </span>
          </div>
        </div>
      </div>
      <div className="mt-6 bg-white dark:bg-neutral-950">
        <Suspense
          fallback={
            <div className="flex items-center justify-center h-full">
              <div className="text-neutral-500 dark:text-neutral-400 text-sm select-none">
                Loading diffs...
              </div>
            </div>
          }
        >
          {currentPR?.repoFullName && currentPR.baseRef && currentPR.headRef ? (
            <RunDiffSection
              repoFullName={currentPR.repoFullName}
              ref1={refWithOrigin(currentPR.baseRef)}
              ref2={refWithOrigin(currentPR.headRef)}
              onControlsChange={setDiffControls}
              classNames={gitDiffViewerClassNames}
            />
          ) : (
            <div className="px-6 text-sm text-neutral-600 dark:text-neutral-300">
              Missing repo or branches to show diff.
            </div>
          )}
        </Suspense>
      </div>
    </div>
  );
}
