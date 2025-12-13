import { EnvironmentConfiguration } from "@/components/EnvironmentConfiguration";
import { FloatingPane } from "@/components/floating-pane";
import { TitleBar } from "@/components/TitleBar";
import { parseEnvBlock } from "@/lib/parseEnvBlock";
import { toMorphVncWebsocketUrl } from "@/lib/toProxyWorkspaceUrl";
import { clearEnvironmentDraft } from "@/state/environment-draft-store";
import type { Id } from "@cmux/convex/dataModel";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import {
  getApiEnvironmentsByIdOptions,
  getApiEnvironmentsByIdVarsOptions,
  getApiEnvironmentsByIdSnapshotsOptions,
} from "@cmux/www-openapi-client/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { z } from "zod";

const searchSchema = z.object({
  selectedRepos: z.array(z.string()).default([]),
  instanceId: z.string().optional(),
  connectionLogin: z.string().optional(),
  repoSearch: z.string().optional(),
  sourceEnvironmentId: z.string(),
  step: z.enum(["select", "configure"]).default("configure"),
  vscodeUrl: z.string().optional(),
});

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/environments/new-version"
)({
  component: NewSnapshotVersionPage,
  validateSearch: searchSchema,
});

function NewSnapshotVersionPage() {
  const { teamSlugOrId } = Route.useParams();
  const searchParams = Route.useSearch();
  const sourceEnvironmentId = typedZid("environments").parse(
    searchParams.sourceEnvironmentId
  ) as Id<"environments">;
  const urlSelectedRepos = searchParams.selectedRepos ?? [];
  const urlInstanceId = searchParams.instanceId;
  const urlVscodeUrl = searchParams.vscodeUrl;
  const [headerActions, setHeaderActions] = useState<ReactNode | null>(null);

  const derivedVscodeUrl = useMemo(() => {
    if (!urlInstanceId) return undefined;
    const hostId = urlInstanceId.replace(/_/g, "-");
    return `https://port-39378-${hostId}.http.cloud.morph.so/?folder=/root/workspace`;
  }, [urlInstanceId]);

  const derivedBrowserWebsocketUrl = useMemo(() => {
    if (urlInstanceId) {
      const hostId = urlInstanceId.replace(/_/g, "-");
      const workspaceUrl = `https://port-39378-${hostId}.http.cloud.morph.so/?folder=/root/workspace`;
      return toMorphVncWebsocketUrl(workspaceUrl) ?? undefined;
    }
    if (urlVscodeUrl) {
      return toMorphVncWebsocketUrl(urlVscodeUrl) ?? undefined;
    }
    if (derivedVscodeUrl) {
      return toMorphVncWebsocketUrl(derivedVscodeUrl) ?? undefined;
    }
    return undefined;
  }, [urlInstanceId, urlVscodeUrl, derivedVscodeUrl]);

  const environmentQuery = useQuery({
    ...getApiEnvironmentsByIdOptions({
      path: { id: String(sourceEnvironmentId) },
      query: { teamSlugOrId },
    }),
    enabled: !!sourceEnvironmentId,
  });

  const environmentVarsQuery = useQuery({
    ...getApiEnvironmentsByIdVarsOptions({
      path: { id: String(sourceEnvironmentId) },
      query: { teamSlugOrId },
    }),
    enabled: !!sourceEnvironmentId,
  });

  const snapshotVersionsQuery = useQuery({
    ...getApiEnvironmentsByIdSnapshotsOptions({
      path: { id: String(sourceEnvironmentId) },
      query: { teamSlugOrId },
    }),
    enabled: !!sourceEnvironmentId,
  });

  const handleEnvironmentSaved = useCallback(() => {
    clearEnvironmentDraft(teamSlugOrId);
  }, [teamSlugOrId]);

  if (environmentQuery.error) {
    throw environmentQuery.error;
  }
  if (environmentVarsQuery.error) {
    throw environmentVarsQuery.error;
  }
  if (snapshotVersionsQuery.error) {
    throw snapshotVersionsQuery.error;
  }

  const isLoading =
    environmentQuery.isPending ||
    environmentVarsQuery.isPending ||
    snapshotVersionsQuery.isPending;
  const environment = environmentQuery.data;

  useEffect(() => {
    if (isLoading || !environment) {
      setHeaderActions(null);
    }
  }, [environment, isLoading]);

  if (!environment && !isLoading) {
    throw new Error("Environment not found");
  }

  const initialEnvVars = useMemo(() => {
    const content = environmentVarsQuery.data?.envVarsContent;
    if (!content) {
      return [];
    }
    return parseEnvBlock(content).map((entry) => ({
      name: entry.name,
      value: entry.value,
      isSecret: true,
    }));
  }, [environmentVarsQuery.data?.envVarsContent]);

  const activeSnapshotScripts = useMemo(() => {
    const snapshots = snapshotVersionsQuery.data ?? [];
    const activeSnapshot = snapshots.find((snapshot) => snapshot.isActive);
    if (!activeSnapshot) {
      return {
        maintenanceScript: environment?.maintenanceScript ?? "",
        devScript: environment?.devScript ?? "",
      };
    }
    return {
      maintenanceScript: activeSnapshot.maintenanceScript ?? environment?.maintenanceScript ?? "",
      devScript: activeSnapshot.devScript ?? environment?.devScript ?? "",
    };
  }, [snapshotVersionsQuery.data, environment?.maintenanceScript, environment?.devScript]);

  const effectiveVscodeUrl = urlVscodeUrl ?? derivedVscodeUrl;

  return (
    <FloatingPane
      header={<TitleBar title="New Snapshot Version" actions={headerActions} />}
    >
      <div className="flex flex-col grow select-none relative h-full overflow-hidden">
        {isLoading || !environment ? (
          <div className="flex h-full items-center justify-center">
            <div className="flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400">
              <Loader2 className="h-4 w-4 animate-spin" />
              Loading snapshot configuration…
            </div>
          </div>
        ) : (
          <EnvironmentConfiguration
            key={String(sourceEnvironmentId)}
            selectedRepos={urlSelectedRepos}
            teamSlugOrId={teamSlugOrId}
            instanceId={urlInstanceId}
            vscodeUrl={effectiveVscodeUrl}
            browserWebsocketUrl={derivedBrowserWebsocketUrl}
            isProvisioning={false}
            mode="snapshot"
            sourceEnvironmentId={sourceEnvironmentId}
            initialEnvName={environment.name}
            initialMaintenanceScript={activeSnapshotScripts.maintenanceScript}
            initialDevScript={activeSnapshotScripts.devScript}
            initialExposedPorts={
              environment.exposedPorts && environment.exposedPorts.length > 0
                ? environment.exposedPorts.join(", ")
                : ""
            }
            initialEnvVars={initialEnvVars}
            onHeaderControlsChange={setHeaderActions}
            onEnvironmentSaved={handleEnvironmentSaved}
          />
        )}
      </div>
    </FloatingPane>
  );
}
