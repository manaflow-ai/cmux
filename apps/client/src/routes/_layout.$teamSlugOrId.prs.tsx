import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { api } from "@cmux/convex/api";
import {
  createFileRoute,
  Link,
  Outlet,
  useLocation,
} from "@tanstack/react-router";
import { useQuery as useConvexQuery } from "convex/react";
import { useMemo, useState } from "react";

function formatTimeAgo(input?: string): string {
  if (!input) return "";
  const ts = Date.parse(input);
  if (Number.isNaN(ts)) return "";
  const diff = Date.now() - ts;
  const sec = Math.floor(diff / 1000);
  if (sec < 60) return "just now";
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}d ago`;
  const mo = Math.floor(day / 30);
  if (mo < 12) return `${mo}mo ago`;
  const yr = Math.floor(mo / 12);
  return `${yr}y ago`;
}

export const Route = createFileRoute("/_layout/$teamSlugOrId/prs")({
  component: PRsPage,
  loader: async (opts) => {
    const { teamSlugOrId } = opts.params;
    convexQueryClient.convexClient.prewarmQuery({
      query: api.github.listProviderConnections,
      args: { teamSlugOrId },
    });
    convexQueryClient.convexClient.prewarmQuery({
      query: api.github_prs.listPullRequests,
      args: { teamSlugOrId, state: "open", search: "" },
    });
  },
});

function PRsPage() {
  const { teamSlugOrId } = Route.useParams();
  const connections = useConvexQuery(api.github.listProviderConnections, {
    teamSlugOrId,
  });
  const activeConnections = (connections || []).filter((c) => c.isActive);
  const [installationId, setInstallationId] = useState<number | null>(
    activeConnections.length > 0 ? activeConnections[0]!.installationId : null
  );
  const [search, setSearch] = useState("");
  const [state, setState] = useState<"open" | "closed" | "all">("open");
  const selected = useMemo(
    () =>
      activeConnections.find((c) => c.installationId === installationId) ||
      null,
    [activeConnections, installationId]
  );

  const prs = useConvexQuery(api.github_prs.listPullRequests, {
    teamSlugOrId,
    state,
    search,
  });
  const filteredPrs = useMemo(() => {
    const list = (prs || []).filter((p) =>
      selected?.installationId
        ? p.installationId === selected.installationId
        : true
    );
    return list;
  }, [prs, selected?.installationId]);

  const location = useLocation();
  const selectedKey = useMemo(() => {
    const segs = location.pathname.split("/").filter(Boolean);
    const idx = segs.indexOf("prs");
    if (idx >= 0 && segs.length >= idx + 4) {
      const owner = segs[idx + 1] || "";
      const repo = segs[idx + 2] || "";
      const num = segs[idx + 3] || "";
      if (owner && repo && num) return `${owner}/${repo}#${num}`;
    }
    return null;
  }, [location.pathname]);

  return (
    <div className="flex flex-row grow min-h-0 w-full bg-white dark:bg-black h-screen">
      {/* Left list */}
      <div className="w-[420px] border-r border-neutral-200 dark:border-neutral-800 flex flex-col min-h-0 border-l">
        <div className="p-3 border-b border-neutral-200 dark:border-neutral-800 flex gap-2 items-center">
          <select
            className="flex-0 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 px-2 py-1 text-sm"
            value={installationId ?? ""}
            onChange={(e) => setInstallationId(Number(e.target.value) || null)}
          >
            {activeConnections.map((c) => (
              <option key={c.installationId} value={c.installationId}>
                {c.accountLogin}
              </option>
            ))}
          </select>
          <input
            placeholder="Search PRs"
            className="flex-1 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 px-2 py-1 text-sm"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <select
            className="flex-0 rounded-md border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900 text-neutral-900 dark:text-neutral-100 px-2 py-1 text-sm"
            value={state}
            onChange={(e) => setState(e.target.value as typeof state)}
          >
            <option value="open">Open</option>
            <option value="closed">Closed</option>
            <option value="all">All</option>
          </select>
        </div>
        <div className="flex-1 overflow-auto">
          {!prs ? (
            <div className="p-4 text-neutral-500">Loading…</div>
          ) : filteredPrs.length === 0 ? (
            <div className="p-4 text-neutral-500">No pull requests found</div>
          ) : (
            <ul>
              {filteredPrs.map((pr) => {
                const [owner, repo] = pr.repoFullName.split("/", 2);
                const isSelected =
                  selectedKey === `${pr.repoFullName}#${pr.number}`;
                return (
                  <li
                    key={`${pr.repoFullName}#${pr.number}`}
                    className="border-b border-neutral-100 dark:border-neutral-900"
                  >
                    <Link
                      to="/$teamSlugOrId/prs/$owner/$repo/$number"
                      params={{
                        teamSlugOrId,
                        owner: owner || "",
                        repo: repo || "",
                        number: String(pr.number),
                      }}
                      className={`block px-4 py-3 hover:bg-neutral-50 dark:hover:bg-neutral-900/50 ${
                        isSelected ? "bg-neutral-50 dark:bg-neutral-900/50" : ""
                      }`}
                    >
                      <div className="text-sm font-medium text-neutral-900 dark:text-neutral-100 truncate">
                        {pr.title}
                      </div>
                      <div className="text-xs text-neutral-600 dark:text-neutral-400 mt-0.5">
                        {pr.repoFullName}#{pr.number} • {pr.authorLogin || ""} •{" "}
                        {formatTimeAgo(
                          pr.updatedAt
                            ? new Date(pr.updatedAt).toISOString()
                            : undefined
                        )}
                      </div>
                    </Link>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>

      {/* Right panel details */}
      <div className="flex-1 min-w-0 bg-white dark:bg-black overflow-auto">
        {selectedKey ? (
          <Outlet />
        ) : (
          <div className="h-full w-full flex items-center justify-center text-neutral-500 dark:text-neutral-400">
            Select a pull request
          </div>
        )}
      </div>
    </div>
  );
}
