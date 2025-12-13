import { EnvironmentConfiguration } from "@/components/EnvironmentConfiguration";
import { FloatingPane } from "@/components/floating-pane";
import { RepositoryPicker } from "@/components/RepositoryPicker";
import { TitleBar } from "@/components/TitleBar";
import { toMorphVncWebsocketUrl } from "@/lib/toProxyWorkspaceUrl";
import {
  clearEnvironmentDraft,
  persistEnvironmentDraftMetadata,
  updateEnvironmentDraftConfig,
  useEnvironmentDraft,
} from "@/state/environment-draft-store";
import type { EnvironmentConfigDraft } from "@/types/environment";
import {
  DEFAULT_MORPH_SNAPSHOT_ID,
  MORPH_SNAPSHOT_PRESETS,
  type MorphSnapshotId,
} from "@cmux/shared";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { ArrowLeft } from "lucide-react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { z } from "zod";

const morphSnapshotIds = MORPH_SNAPSHOT_PRESETS.map(
  (preset) => preset.id
) as [MorphSnapshotId, ...MorphSnapshotId[]];

const searchSchema = z.object({
  step: z.enum(["select", "configure"]).default("select"),
  selectedRepos: z.array(z.string()).default([]),
  instanceId: z.string().optional(),
  connectionLogin: z.string().optional(),
  repoSearch: z.string().optional(),
  snapshotId: z.enum(morphSnapshotIds).default(DEFAULT_MORPH_SNAPSHOT_ID),
});

const haveSameRepos = (
  a: readonly string[],
  b: readonly string[],
): boolean => {
  if (a.length !== b.length) {
    return false;
  }
  const counts = new Map<string, number>();
  for (const repo of a) {
    counts.set(repo, (counts.get(repo) ?? 0) + 1);
  }
  for (const repo of b) {
    const next = counts.get(repo);
    if (!next) {
      return false;
    }
    if (next === 1) {
      counts.delete(repo);
    } else {
      counts.set(repo, next - 1);
    }
  }
  return counts.size === 0;
};

export const Route = createFileRoute("/_layout/$teamSlugOrId/environments/new")(
  {
    component: EnvironmentsPage,
    validateSearch: searchSchema,
  }
);

function EnvironmentsPage() {
  const searchParams = Route.useSearch();
  const stepFromSearch = searchParams.step ?? "select";
  const urlSelectedRepos = searchParams.selectedRepos ?? [];
  const urlInstanceId = searchParams.instanceId;
  const searchSnapshotId =
    searchParams.snapshotId ?? DEFAULT_MORPH_SNAPSHOT_ID;
  const { teamSlugOrId } = Route.useParams();
  const navigate = useNavigate({ from: Route.fullPath });
  const draft = useEnvironmentDraft(teamSlugOrId);
  const [headerActions, setHeaderActions] = useState<ReactNode | null>(null);
  const skipDraftHydrationRef = useRef(false);

  const activeStep = draft?.step ?? stepFromSearch;
  const activeSelectedRepos = draft?.selectedRepos ?? urlSelectedRepos;
  const activeInstanceId = draft?.instanceId ?? urlInstanceId;
  const activeSnapshotId = draft?.snapshotId ?? searchSnapshotId;

  const derivedVscodeUrl = useMemo(() => {
    if (!activeInstanceId) return undefined;
    const hostId = activeInstanceId.replace(/_/g, "-");
    return `https://port-39378-${hostId}.http.cloud.morph.so/?folder=/root/workspace`;
  }, [activeInstanceId]);

  const derivedBrowserWebsocketUrl = useMemo(() => {
    if (!activeInstanceId) return undefined;
    const hostId = activeInstanceId.replace(/_/g, "-");
    const workspaceUrl = `https://port-39378-${hostId}.http.cloud.morph.so/?folder=/root/workspace`;
    return toMorphVncWebsocketUrl(workspaceUrl) ?? undefined;
  }, [activeInstanceId]);

  useEffect(() => {
    if (activeStep !== "configure") {
      setHeaderActions(null);
    }
  }, [activeStep]);

  useEffect(() => {
    if (activeStep !== "configure" || draft || skipDraftHydrationRef.current) {
      return;
    }
    persistEnvironmentDraftMetadata(
      teamSlugOrId,
      {
        selectedRepos: activeSelectedRepos,
        instanceId: activeInstanceId,
        snapshotId: activeSnapshotId,
      },
      { resetConfig: false, step: "configure" },
    );
  }, [
    activeInstanceId,
    activeSelectedRepos,
    activeSnapshotId,
    activeStep,
    draft,
    teamSlugOrId,
  ]);

  const handleStartConfigure = useCallback(
    (payload: {
      selectedRepos: string[];
      instanceId?: string;
      snapshotId?: MorphSnapshotId;
    }) => {
      const existingRepos = draft?.selectedRepos ?? [];
      const reposChanged = !haveSameRepos(existingRepos, payload.selectedRepos);
      const instanceChanged = draft?.instanceId !== payload.instanceId;
      const snapshotChanged = draft?.snapshotId !== payload.snapshotId;
      const shouldResetConfig =
        !draft || reposChanged || instanceChanged || snapshotChanged;

      skipDraftHydrationRef.current = false;
      persistEnvironmentDraftMetadata(
        teamSlugOrId,
        {
          selectedRepos: payload.selectedRepos,
          instanceId: payload.instanceId,
          snapshotId: payload.snapshotId,
        },
        { resetConfig: shouldResetConfig, step: "configure" },
      );
    },
    [draft, teamSlugOrId],
  );

  const handlePersistConfig = useCallback(
    (partial: Partial<EnvironmentConfigDraft>) => {
      updateEnvironmentDraftConfig(teamSlugOrId, partial, {
        selectedRepos: activeSelectedRepos,
        instanceId: activeInstanceId,
        snapshotId: activeSnapshotId,
      });
    },
    [teamSlugOrId, activeInstanceId, activeSelectedRepos, activeSnapshotId],
  );

  const handleBackToRepositorySelection = useCallback(() => {
    persistEnvironmentDraftMetadata(
      teamSlugOrId,
      {
        selectedRepos: activeSelectedRepos,
        instanceId: activeInstanceId,
        snapshotId: activeSnapshotId,
      },
      { resetConfig: false, step: "select" },
    );
  }, [activeInstanceId, activeSelectedRepos, activeSnapshotId, teamSlugOrId]);

  const handleResetDraft = useCallback(() => {
    skipDraftHydrationRef.current = true;
    clearEnvironmentDraft(teamSlugOrId);
    setHeaderActions(null);
  }, [teamSlugOrId]);

  const handleDiscardAndExit = useCallback(async () => {
    handleResetDraft();
    await navigate({
      to: "/$teamSlugOrId/environments",
      params: { teamSlugOrId },
      search: {
        step: undefined,
        selectedRepos: undefined,
        connectionLogin: undefined,
        repoSearch: undefined,
        instanceId: undefined,
        snapshotId: undefined,
      },
    });
  }, [handleResetDraft, navigate, teamSlugOrId]);

  return (
    <FloatingPane header={<TitleBar title="Environments" actions={headerActions} />}>
      <div className="flex flex-col grow select-none relative h-full overflow-hidden">
        {activeStep === "select" ? (
          <div className="p-6 max-w-3xl w-full mx-auto overflow-auto">
            <RepositoryPicker
              teamSlugOrId={teamSlugOrId}
              instanceId={activeInstanceId}
              initialSelectedRepos={activeSelectedRepos}
              initialSnapshotId={activeSnapshotId}
              showHeader={true}
              showContinueButton={true}
              showManualConfigOption={true}
              onStartConfigure={handleStartConfigure}
              topAccessory={
                <button
                  type="button"
                  onClick={handleDiscardAndExit}
                  className="inline-flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100 transition-colors"
                >
                  <ArrowLeft className="w-4 h-4" />
                  Back to environments
                </button>
              }
            />
          </div>
        ) : (
          <EnvironmentConfiguration
            selectedRepos={activeSelectedRepos}
            teamSlugOrId={teamSlugOrId}
            instanceId={activeInstanceId}
            vscodeUrl={derivedVscodeUrl}
            browserWebsocketUrl={derivedBrowserWebsocketUrl}
            isProvisioning={false}
            onHeaderControlsChange={setHeaderActions}
            persistedState={draft?.config}
            onPersistStateChange={handlePersistConfig}
            onBackToRepositorySelection={handleBackToRepositorySelection}
            onEnvironmentSaved={handleResetDraft}
          />
        )}
      </div>
    </FloatingPane>
  );
}
