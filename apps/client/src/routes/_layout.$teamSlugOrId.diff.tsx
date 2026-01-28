import { GitDiffViewerWithSidebar } from "@/components/git-diff-viewer";
import { GitHubIcon } from "@/components/icons/github";
import {
  SearchableSelect,
  type SelectOption,
} from "@/components/ui/searchable-select";
import { useSocket } from "@/contexts/socket/use-socket";
import { getApiIntegrationsGithubBranchesOptions } from "@/queries/branches";
import { gitDiffQueryOptions } from "@/queries/git-diff";
import { api } from "@cmux/convex/api";
import { convexQuery } from "@convex-dev/react-query";
import { useQuery as useRQ } from "@tanstack/react-query";
import { createFileRoute, useRouter } from "@tanstack/react-router";
import { ArrowLeftRight, GitBranch } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";

export const Route = createFileRoute("/_layout/$teamSlugOrId/diff")({
  component: DashboardDiffPage,
});

type DiffSearch = {
  ref1?: string;
  ref2?: string;
};

function DashboardDiffPage() {
  const { teamSlugOrId } = Route.useParams();
  const search = Route.useSearch() as DiffSearch;
  const router = useRouter();
  const { socket } = useSocket();

  const [selectedProject, setSelectedProject] = useState<string | null>(() => {
    try {
      const stored = localStorage.getItem("selectedProject");
      const parsed = stored ? (JSON.parse(stored) as string[]) : [];
      return parsed[0] || null;
    } catch {
      return null;
    }
  });

  useEffect(() => {
    if (selectedProject) return;
    const onDefaultRepo = (payload: unknown) => {
      const data = payload as { repoFullName: string; branch?: string };
      if (!data || typeof data.repoFullName !== "string") return;
      setSelectedProject(data.repoFullName);
      localStorage.setItem(
        "selectedProject",
        JSON.stringify([data.repoFullName])
      );
    };
    // Rely on SocketProvider attaching a socket to window if available
    const w = window as unknown as {
      cmuxSocket?: {
        on: (event: string, cb: (data: unknown) => void) => void;
        off: (event: string, cb: (data: unknown) => void) => void;
      };
    };
    if (w.cmuxSocket && typeof w.cmuxSocket.on === "function") {
      w.cmuxSocket.on("default-repo", onDefaultRepo);
      return () => {
        w.cmuxSocket?.off?.("default-repo", onDefaultRepo);
      };
    }
    return () => {};
  }, [selectedProject]);

  const isEnvironmentProject =
    !!selectedProject && selectedProject.startsWith("env:");

  const reposByOrgQuery = useRQ(
    convexQuery(api.github.getReposByOrg, { teamSlugOrId })
  );

  const branchesQuery = useRQ({
    ...getApiIntegrationsGithubBranchesOptions({
      query: { repo: selectedProject || "" },
    }),
    staleTime: 10_000,
    enabled: !!selectedProject && !isEnvironmentProject,
  });

  const projectOptions: SelectOption[] = useMemo(() => {
    const byOrg =
      (reposByOrgQuery.data as
        | Record<string, Array<{ fullName: string }>>
        | undefined) || {};
    const repoValues = Array.from(
      new Set(
        Object.entries(byOrg).flatMap(([, repos]) =>
          repos.map((r) => r.fullName)
        )
      )
    );
    const repoOptions = repoValues.map((fullName) => ({
      label: fullName,
      value: fullName,
      icon: (
        <GitHubIcon className="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
      ),
      iconKey: "github",
    }));
    const opts: SelectOption[] = [];
    if (repoOptions.length > 0) {
      opts.push({
        label: "Repositories",
        value: "__heading-repo",
        heading: true,
      });
      opts.push(...repoOptions);
    }
    return opts;
  }, [reposByOrgQuery.data]);

  const branchOptions: SelectOption[] = useMemo(() => {
    const names = (branchesQuery.data?.branches ?? []).map((branch) => branch.name);
    // Avoid duplicate icons by not adding per-option icons; use leftIcon on control instead
    return names.map((name) => ({ label: name, value: name }));
  }, [branchesQuery.data]);

  const setSearch = useCallback(
    (next: Partial<DiffSearch>) => {
      void router.navigate({
        to: "/$teamSlugOrId/diff",
        params: { teamSlugOrId },
        search: {
          ref1: next.ref1 ?? search.ref1,
          ref2: next.ref2 ?? search.ref2,
        },
        replace: true,
      });
    },
    [router, teamSlugOrId, search.ref1, search.ref2]
  );

  const onChangeRef1 = useCallback(
    (vals: string[]) => {
      setSearch({ ref1: vals[0] });
    },
    [setSearch]
  );
  const onChangeRef2 = useCallback(
    (vals: string[]) => {
      setSearch({ ref2: vals[0] });
    },
    [setSearch]
  );

  const swapRefs = useCallback(() => {
    setSearch({ ref1: search.ref2, ref2: search.ref1 });
  }, [search.ref1, search.ref2, setSearch]);

  const bothSelected = !!search.ref1 && !!search.ref2 && !!selectedProject;
  const diffsQuery = useRQ({
    ...gitDiffQueryOptions({
      repoFullName: selectedProject!,
      baseRef: search.ref1,
      headRef: search.ref2!,
    }),
    enabled: Boolean(selectedProject && search.ref1 && search.ref2),
  });

  useEffect(() => {
    if (diffsQuery.isError) {
      const err = diffsQuery.error as unknown;
      const msg = err instanceof Error ? err.message : String(err ?? "");
      toast.error("Failed to load diffs", { description: msg });
    }
  }, [diffsQuery.isError, diffsQuery.error]);

  // On socket connect, kick a refetch if we have required selections
  useEffect(() => {
    if (socket && bothSelected) {
      void diffsQuery.refetch();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [socket, bothSelected]);

  return (
    <div className="flex flex-col h-screen min-h-0 grow">
      <div className="border-b border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 px-3 py-2 flex items-center gap-2">
        <SearchableSelect
          options={projectOptions}
          value={selectedProject ? [selectedProject] : []}
          onChange={(vals) => {
            const v = vals[0];
            setSelectedProject(v ?? null);
            localStorage.setItem(
              "selectedProject",
              JSON.stringify(v ? [v] : [])
            );
            // Clear refs when repo changes
            setSearch({ ref1: undefined, ref2: undefined });
          }}
          placeholder="Select repository"
          singleSelect
          className="h-8"
          loading={reposByOrgQuery.isLoading}
        />
        <SearchableSelect
          options={branchOptions}
          value={search.ref1 ? [search.ref1] : []}
          onChange={onChangeRef1}
          placeholder="Select ref 1"
          singleSelect
          leftIcon={<GitBranch className="h-3.5 w-3.5 text-neutral-500" />}
          className="h-8"
          disabled={!selectedProject}
          loading={branchesQuery.isLoading}
        />
        <button
          type="button"
          onClick={swapRefs}
          className="inline-flex items-center justify-center h-8 w-8 rounded-md border border-neutral-200 dark:border-neutral-800 text-neutral-600 dark:text-neutral-300 bg-white dark:bg-neutral-950 hover:bg-neutral-50 dark:hover:bg-neutral-900"
          aria-label="Swap refs"
        >
          <ArrowLeftRight className="h-4 w-4" />
        </button>
        <SearchableSelect
          options={branchOptions}
          value={search.ref2 ? [search.ref2] : []}
          onChange={onChangeRef2}
          placeholder="Select ref 2"
          singleSelect
          leftIcon={<GitBranch className="h-3.5 w-3.5 text-neutral-500" />}
          className="h-8"
          disabled={!selectedProject}
          loading={branchesQuery.isLoading}
        />
      </div>
      <div className="flex-1 flex flex-col bg-white dark:bg-neutral-950 overflow-y-auto grow">
        {/* Smart view with sidebar */}
        <GitDiffViewerWithSidebar
          diffs={diffsQuery.data || []}
          onControlsChange={() => {}}
        />
        {!bothSelected ? (
          <div className="px-3 py-2 text-sm text-neutral-500 dark:text-neutral-400">
            Select a repository and two refs to compare.
          </div>
        ) : null}
      </div>
    </div>
  );
}
