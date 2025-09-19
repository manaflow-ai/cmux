import { ResizableColumns } from "@/components/ResizableColumns";
import { FloatingPane } from "@/components/floating-pane";
import { PRsRightPanel } from "@/components/prs/PRsRightPanel";
import { PullRequestListPanel } from "@/components/prs/PullRequestListPanel";
import { api } from "@cmux/convex/api";
import { useLocation } from "@tanstack/react-router";
import { useQuery as useConvexQuery } from "convex/react";
import { useMemo, useState } from "react";
import type { ReactNode } from "react";

type PullRequestState = "open" | "closed" | "all";

export interface PRsWorkspaceProps {
  teamSlugOrId: string;
  emptyState?: ReactNode;
  leftStorageKey?: string;
  defaultState?: PullRequestState;
}

export function PRsWorkspace({
  teamSlugOrId,
  emptyState,
  leftStorageKey = "prs.leftWidth",
  defaultState = "open",
}: PRsWorkspaceProps) {
  const connections = useConvexQuery(api.github.listProviderConnections, {
    teamSlugOrId,
  });
  const activeConnections = (connections || []).filter((c) => c.isActive);
  const [installationId, setInstallationId] = useState<number | null>(
    activeConnections.length > 0 ? activeConnections[0]!.installationId : null
  );
  const [search, setSearch] = useState("");
  const [state, setState] = useState<PullRequestState>(defaultState);

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
    <FloatingPane>
      <div className="flex flex-1 min-h-0 h-full flex-col">
        <div className="flex-1 min-h-0 h-full">
          <ResizableColumns
            storageKey={leftStorageKey}
            defaultLeftWidth={355}
            minLeft={260}
            maxLeft={720}
            separatorWidth={6}
            className="flex-1 min-h-0 h-full w-full bg-white dark:bg-black"
            separatorClassName="bg-neutral-100 dark:bg-neutral-900 hover:bg-neutral-200 dark:hover:bg-neutral-800 active:bg-neutral-300 dark:active:bg-neutral-700"
            left={
              <PullRequestListPanel
                teamSlugOrId={teamSlugOrId}
                activeConnections={activeConnections.map((c) => ({
                  installationId: c.installationId,
                  accountLogin: c.accountLogin ?? "",
                }))}
                installationId={installationId}
                onInstallationIdChange={(id) => setInstallationId(id)}
                search={search}
                onSearchChange={setSearch}
                state={state}
                onStateChange={(s) => setState(s)}
                selectedKey={selectedKey}
              />
            }
            right={<PRsRightPanel selectedKey={selectedKey} emptyState={emptyState} />}
          />
        </div>
      </div>
    </FloatingPane>
  );
}
