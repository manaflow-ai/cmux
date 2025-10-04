import { EditableLabel } from "@/components/editable-label";
import { FloatingPane } from "@/components/floating-pane";
import { ScriptTextareaField } from "@/components/ScriptTextareaField";
import { SCRIPT_COPY } from "@/components/scriptCopy";
import { TitleBar } from "@/components/TitleBar";
import { queryClient } from "@/query-client";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { validateExposedPorts } from "@cmux/shared/utils/validate-exposed-ports";
import {
  patchApiEnvironmentsByIdPortsMutation,
  patchApiEnvironmentsByIdMutation,
  postApiEnvironmentsByIdSnapshotsBySnapshotVersionIdActivateMutation,
  postApiSandboxesStartMutation,
} from "@cmux/www-openapi-client/react-query";
import { convexQuery } from "@convex-dev/react-query";
import {
  useMutation as useRQMutation,
  useSuspenseQuery,
} from "@tanstack/react-query";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useMutation } from "convex/react";
import { formatDistanceToNow } from "date-fns";
import {
  ArrowLeft,
  Calendar,
  Code,
  GitBranch,
  Loader2,
  Package,
  Plus,
  Server,
  Terminal,
  Trash2,
  X,
} from "lucide-react";
import { type KeyboardEvent, useEffect, useMemo, useState } from "react";
import { toast } from "sonner";

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/environments/$environmentId",
)({
  parseParams: (params) => ({
    ...params,
    environmentId: typedZid("environments").parse(params.environmentId),
  }),
  loader: async ({ params }) => {
    void queryClient.ensureQueryData(
      convexQuery(api.environments.get, {
        teamSlugOrId: params.teamSlugOrId,
        id: params.environmentId,
      }),
    );
    void queryClient.ensureQueryData(
      convexQuery(api.environmentSnapshots.list, {
        teamSlugOrId: params.teamSlugOrId,
        environmentId: params.environmentId,
      }),
    );
    void queryClient.ensureQueryData(
      convexQuery(api.environments.get, {
        teamSlugOrId: params.teamSlugOrId,
        id: params.environmentId,
      }),
    );
  },
  component: EnvironmentDetailsPage,
  validateSearch: () => ({}),
});

function EnvironmentDetailsPage() {
  const { teamSlugOrId, environmentId } = Route.useParams();
  const navigate = useNavigate({ from: Route.fullPath });
  const [isDeleting, setIsDeleting] = useState(false);
  const environmentQuery = convexQuery(api.environments.get, {
    teamSlugOrId,
    id: environmentId,
  });
  const { data: environment } = useSuspenseQuery(environmentQuery);
  if (!environment) {
    throw new Error("Environment not found");
  }
  const snapshotsQuery = convexQuery(api.environmentSnapshots.list, {
    teamSlugOrId,
    environmentId,
  });
  const { data: snapshotVersions } = useSuspenseQuery(snapshotsQuery);
  const deleteEnvironment = useMutation(api.environments.remove);
  const deleteSnapshotVersion = useMutation(api.environmentSnapshots.remove);
  const updatePortsMutation = useRQMutation(
    patchApiEnvironmentsByIdPortsMutation(),
  );
  const updateEnvironmentMutation = useRQMutation(
    patchApiEnvironmentsByIdMutation(),
  );
  const updateDevScriptMutation = useRQMutation(
    patchApiEnvironmentsByIdMutation(),
  );
  const updateMaintenanceScriptMutation = useRQMutation(
    patchApiEnvironmentsByIdMutation(),
  );
  const activateSnapshotMutation = useRQMutation(
    postApiEnvironmentsByIdSnapshotsBySnapshotVersionIdActivateMutation(),
  );
  const modifyVmMutation = useRQMutation(postApiSandboxesStartMutation());
  const snapshotLaunchMutation = useRQMutation(postApiSandboxesStartMutation());
  const [renameError, setRenameError] = useState<string | null>(null);
  const [isEditingPorts, setIsEditingPorts] = useState(false);
  const [portsDraft, setPortsDraft] = useState<number[]>(
    environment.exposedPorts ?? [],
  );
  const [portInput, setPortInput] = useState("");
  const [portsError, setPortsError] = useState<string | null>(null);
  const [activatingVersionId, setActivatingVersionId] = useState<string | null>(
    null,
  );
  const [deletingVersionId, setDeletingVersionId] = useState<string | null>(null);
  const [isEditingDevScript, setIsEditingDevScript] = useState(false);
  const [devScriptDraft, setDevScriptDraft] = useState(
    environment.devScript ?? "",
  );
  const [isEditingMaintenanceScript, setIsEditingMaintenanceScript] =
    useState(false);
  const [maintenanceScriptDraft, setMaintenanceScriptDraft] = useState(
    environment.maintenanceScript ?? "",
  );

  const handleRenameStart = () => {
    updateEnvironmentMutation.reset();
    setRenameError(null);
  };

  const handleRenameCancel = () => {
    updateEnvironmentMutation.reset();
    setRenameError(null);
  };

  const handleRename = async (nextName: string) => {
    const trimmedName = nextName.trim();
    if (trimmedName.length === 0) {
      setRenameError("Environment name is required.");
      return false;
    }

    const currentName = environment.name.trim();
    if (trimmedName === currentName) {
      setRenameError(null);
      return true;
    }

    try {
      setRenameError(null);
      updateEnvironmentMutation.reset();
      await updateEnvironmentMutation.mutateAsync({
        path: { id: String(environmentId) },
        body: {
          teamSlugOrId,
          name: trimmedName,
        },
      });
      setRenameError(null);
      toast.success("Environment renamed");
      return true;
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to update environment name";
      setRenameError(message);
      toast.error(message);
      return false;
    }
  };

  useEffect(() => {
    if (!isEditingPorts) {
      setPortsDraft(environment.exposedPorts ?? []);
    }
  }, [environment.exposedPorts, isEditingPorts]);

  useEffect(() => {
    if (!isEditingDevScript) {
      setDevScriptDraft(environment.devScript ?? "");
    }
  }, [environment.devScript, isEditingDevScript]);

  useEffect(() => {
    if (!isEditingMaintenanceScript) {
      setMaintenanceScriptDraft(environment.maintenanceScript ?? "");
    }
  }, [environment.maintenanceScript, isEditingMaintenanceScript]);

  const handleStartEditingPorts = () => {
    setPortsDraft(environment.exposedPorts ?? []);
    setPortInput("");
    setPortsError(null);
    setIsEditingPorts(true);
  };

  const hasPortChanges = useMemo(() => {
    const currentPorts = environment.exposedPorts ?? [];
    if (currentPorts.length !== portsDraft.length) {
      return true;
    }

    const sortedCurrent = [...currentPorts].sort((a, b) => a - b);
    const sortedDraft = [...portsDraft].sort((a, b) => a - b);

    return sortedCurrent.some((value, index) => value !== sortedDraft[index]);
  }, [environment.exposedPorts, portsDraft]);

  const handleCancelPorts = () => {
    setIsEditingPorts(false);
    setPortsDraft(environment.exposedPorts ?? []);
    setPortInput("");
    setPortsError(null);
  };

  const handleStartEditingDevScript = () => {
    setDevScriptDraft(environment.devScript ?? "");
    setIsEditingDevScript(true);
    updateDevScriptMutation.reset();
  };

  const handleCancelDevScript = () => {
    setDevScriptDraft(environment.devScript ?? "");
    setIsEditingDevScript(false);
    updateDevScriptMutation.reset();
  };

  const handleSaveDevScript = async () => {
    const normalizedDevScript = devScriptDraft.trim();
    if (normalizedDevScript === (environment.devScript ?? "")) {
      setIsEditingDevScript(false);
      return;
    }

    try {
      await updateDevScriptMutation.mutateAsync({
        path: { id: String(environmentId) },
        body: {
          teamSlugOrId,
          devScript: normalizedDevScript,
        },
      });
      toast.success("Dev script updated");
      setIsEditingDevScript(false);
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to update dev script";
      toast.error(message);
    }
  };

  const handleStartEditingMaintenanceScript = () => {
    setMaintenanceScriptDraft(environment.maintenanceScript ?? "");
    setIsEditingMaintenanceScript(true);
    updateMaintenanceScriptMutation.reset();
  };

  const handleCancelMaintenanceScript = () => {
    setMaintenanceScriptDraft(environment.maintenanceScript ?? "");
    setIsEditingMaintenanceScript(false);
    updateMaintenanceScriptMutation.reset();
  };

  const handleSaveMaintenanceScript = async () => {
    const normalizedMaintenanceScript = maintenanceScriptDraft.trim();
    if (
      normalizedMaintenanceScript === (environment.maintenanceScript ?? "")
    ) {
      setIsEditingMaintenanceScript(false);
      return;
    }

    try {
      await updateMaintenanceScriptMutation.mutateAsync({
        path: { id: String(environmentId) },
        body: {
          teamSlugOrId,
          maintenanceScript: normalizedMaintenanceScript,
        },
      });
      toast.success("Maintenance script updated");
      setIsEditingMaintenanceScript(false);
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to update maintenance script";
      toast.error(message);
    }
  };

  const handleAddPort = () => {
    if (portInput.trim().length === 0) {
      setPortsError("Enter a port number.");
      return;
    }
    const parsed = Number.parseInt(portInput.trim(), 10);
    if (!Number.isFinite(parsed)) {
      setPortsError("Enter a valid port number.");
      return;
    }

    const validation = validateExposedPorts([...portsDraft, parsed]);
    if (validation.reserved.length > 0) {
      setPortsError(
        `Reserved ports cannot be exposed: ${validation.reserved.join(", ")}`,
      );
      return;
    }
    if (validation.invalid.length > 0) {
      setPortsError("Ports must be positive integers.");
      return;
    }

    setPortsDraft(validation.sanitized);
    setPortInput("");
    setPortsError(null);
  };

  const handleRemovePort = (port: number) => {
    setPortsDraft((prev) => prev.filter((value) => value !== port));
  };

  const handlePortInputKeyDown = (
    event: KeyboardEvent<HTMLInputElement>,
  ) => {
    if (event.key === "Enter") {
      event.preventDefault();
      handleAddPort();
    }
  };

  const handleSavePorts = () => {
    const validation = validateExposedPorts(portsDraft);
    if (validation.reserved.length > 0) {
      setPortsError(
        `Reserved ports cannot be exposed: ${validation.reserved.join(", ")}`,
      );
      return;
    }
    if (validation.invalid.length > 0) {
      setPortsError("Ports must be positive integers.");
      return;
    }

    setPortsError(null);
    updatePortsMutation.mutate(
      {
        path: { id: String(environmentId) },
        body: { teamSlugOrId, ports: validation.sanitized },
      },
      {
        onSuccess: async () => {
          setIsEditingPorts(false);
          setPortInput("");
          toast.success("Exposed ports updated");
        },
        onError: (error) => {
          setPortsError(
            error instanceof Error
              ? error.message
              : "Failed to update exposed ports",
          );
        },
      },
    );
  };

  const handleActivateSnapshot = (
    versionId: Id<"environmentSnapshotVersions">,
  ) => {
    const versionIdString = String(versionId);
    setActivatingVersionId(versionIdString);
    activateSnapshotMutation.mutate(
      {
        path: {
          id: String(environmentId),
          snapshotVersionId: versionIdString,
        },
        body: { teamSlugOrId },
      },
      {
        onSuccess: async () => {
          setActivatingVersionId(null);
          toast.success("Snapshot version activated");
        },
        onError: (error) => {
          setActivatingVersionId(null);
          toast.error(
            error instanceof Error
              ? error.message
              : "Failed to activate snapshot",
          );
        },
      },
    );
  };

  const handleDelete = async () => {
    if (
      !confirm(
        "Are you sure you want to delete this environment? This action cannot be undone.",
      )
    ) {
      return;
    }

    setIsDeleting(true);
    try {
      await deleteEnvironment({
        teamSlugOrId,
        id: environmentId,
      });
      toast.success("Environment deleted successfully");
      navigate({
        to: "/$teamSlugOrId/environments",
        params: { teamSlugOrId },
        search: {
          step: undefined,
          selectedRepos: undefined,
          connectionLogin: undefined,
          repoSearch: undefined,
          instanceId: undefined,
        },
      });
    } catch (error) {
      toast.error("Failed to delete environment");
      console.error(error);
    } finally {
      setIsDeleting(false);
    }
  };

  const isModifyPending = modifyVmMutation.isPending;
  const isSnapshotPending = snapshotLaunchMutation.isPending;

  const handleDeleteSnapshotVersion = async (
    versionId: Id<"environmentSnapshotVersions">,
  ) => {
    if (
      !confirm(
        "Are you sure you want to delete this snapshot version? This action cannot be undone.",
      )
    ) {
      return;
    }

    const versionIdString = String(versionId);
    setDeletingVersionId(versionIdString);
    try {
      await deleteSnapshotVersion({
        teamSlugOrId,
        environmentId,
        snapshotVersionId: versionId,
      });
      toast.success("Snapshot version deleted");
      await queryClient.invalidateQueries({ queryKey: snapshotsQuery.queryKey });
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "Failed to delete snapshot version";
      toast.error(message);
    } finally {
      setDeletingVersionId(null);
    }
  };

  const handleSandboxSuccess = (data: { vscodeUrl: string; instanceId: string }) => {
    const baseUrl = data.vscodeUrl;
    const hasQuery = baseUrl.includes("?");
    const vscodeUrlWithFolder = `${baseUrl}${hasQuery ? "&" : "?"}folder=/root/workspace`;
    navigate({
      to: "/$teamSlugOrId/environments/new-version",
      params: { teamSlugOrId },
      search: {
        sourceEnvironmentId: String(environmentId),
        selectedRepos: environment.selectedRepos ?? [],
        connectionLogin: undefined,
        repoSearch: undefined,
        instanceId: data.instanceId,
        vscodeUrl: vscodeUrlWithFolder,
        step: "configure",
      },
    });
  };

  const handleSandboxError = (error: unknown) => {
    const message =
      error instanceof Error
        ? error.message
        : "Failed to launch snapshot environment";
    toast.error(message);
  };

  const handleLaunch = () => {
    navigate({
      to: "/$teamSlugOrId/dashboard",
      params: { teamSlugOrId },
      search: { environmentId },
    });
  };

  const handleModifyVm = () => {
    modifyVmMutation.mutate(
      {
        body: {
          teamSlugOrId,
          environmentId: String(environmentId),
          snapshotId: environment.morphSnapshotId ?? undefined,
        },
      },
      {
        onSuccess: handleSandboxSuccess,
        onError: handleSandboxError,
      },
    );
  };

  const handleStartSnapshotVersion = () => {
    if (!environment.morphSnapshotId) {
      toast.error("Environment is missing a snapshot.");
      return;
    }

    snapshotLaunchMutation.mutate(
      {
        body: {
          teamSlugOrId,
          environmentId: String(environmentId),
          snapshotId: environment.morphSnapshotId,
        },
      },
      {
        onSuccess: handleSandboxSuccess,
        onError: handleSandboxError,
      },
    );
  };

  const sandboxTooltipDescription =
    "Starts a new VS Code instance where you can make changes before saving a snapshot.";

  return (
    <FloatingPane
      header={<TitleBar title={environment?.name || "Environment Details"} />}
    >
      <div className="p-6 max-w-5xl mx-auto w-full">
        {environment ? (
          <div className="space-y-6">
            {/* Back button */}
            <div className="mb-4">
              <Link
                to="/$teamSlugOrId/environments"
                params={{ teamSlugOrId }}
                search={{
                  step: undefined,
                  selectedRepos: undefined,
                  connectionLogin: undefined,
                  repoSearch: undefined,
                  instanceId: undefined,
                }}
                className="inline-flex items-center gap-2 text-sm text-neutral-600 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-neutral-100 transition-colors"
              >
                <ArrowLeft className="w-4 h-4" />
                Back to Environments
              </Link>
            </div>

            {/* Header */}
            <div className="flex items-start justify-between">
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 rounded-lg bg-neutral-100 dark:bg-neutral-900 flex items-center justify-center">
                  <Server className="w-5 h-5 text-neutral-600 dark:text-neutral-400" />
                </div>
                <div className="">
                  <EditableLabel
                    value={environment.name}
                    onEditStart={handleRenameStart}
                    onCancel={handleRenameCancel}
                    onSubmit={handleRename}
                    isSaving={updateEnvironmentMutation.isPending}
                    error={renameError}
                    className="gap-1"
                    labelClassName="text-xl font-semibold text-neutral-900 dark:text-neutral-100"
                    buttonLabel="Rename environment"
                    placeholder="Environment name"
                    ariaLabel="Environment name"
                  />
                  <div className="flex items-center gap-2 text-sm text-neutral-500 dark:text-neutral-500">
                    <Calendar className="w-3 h-3" />
                    Created{" "}
                    {formatDistanceToNow(new Date(environment.createdAt), {
                      addSuffix: true,
                    })}
                  </div>
                </div>
              </div>

              <div className="flex gap-2">
                <button
                  onClick={handleLaunch}
                  className="inline-flex items-center rounded-md bg-neutral-900 text-white px-4 py-2 text-sm font-medium hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200 transition-colors"
                >
                  Start Task
                </button>
                <Tooltip>
                  <TooltipTrigger asChild>
                    <button
                      type="button"
                      onClick={handleModifyVm}
                      disabled={isModifyPending || isSnapshotPending}
                      className={cn(
                        "inline-flex items-center gap-1.5 rounded-md border border-neutral-300 px-4 py-2 text-sm font-medium text-neutral-700 transition-colors disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300",
                        !(isModifyPending || isSnapshotPending) &&
                          "hover:bg-neutral-100 dark:hover:bg-neutral-900",
                      )}
                    >
                      {isModifyPending ? (
                        <>
                          <Loader2 className="h-4 w-4 animate-spin" />
                          Launching…
                        </>
                      ) : (
                        "Modify VM"
                      )}
                    </button>
                  </TooltipTrigger>
                  <TooltipContent className="max-w-xs text-xs leading-snug">
                    {sandboxTooltipDescription}
                  </TooltipContent>
                </Tooltip>
              </div>
            </div>

            {/* Description */}
            {environment.description && (
              <div className="p-4 rounded-lg bg-neutral-50 dark:bg-neutral-900 border border-neutral-200 dark:border-neutral-800">
                <p className="text-sm text-neutral-700 dark:text-neutral-300">
                  {environment.description}
                </p>
              </div>
            )}

            {/* Details Grid */}
            <div className="space-y-6">
              {/* Repositories */}
              {environment.selectedRepos &&
                environment.selectedRepos.length > 0 && (
                  <div>
                    <div className="flex items-center gap-2 mb-3">
                      <GitBranch className="w-4 h-4 text-neutral-500" />
                      <h3 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                        Repositories ({environment.selectedRepos.length})
                      </h3>
                    </div>
                    <div className="space-y-2">
                      {environment.selectedRepos.map((repo: string) => (
                        <div
                          key={repo}
                          className="flex items-center gap-2 p-3 rounded-lg border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950"
                        >
                          <GitBranch className="w-4 h-4 text-neutral-500" />
                          <span className="text-sm text-neutral-700 dark:text-neutral-300">
                            {repo}
                          </span>
                        </div>
                      ))}
                    </div>
                  </div>
                )}

              {/* Scripts */}
              <div className="space-y-4">
                <div>
                  <div className="mb-2 flex items-start justify-between gap-2">
                    <div className="flex items-center gap-2">
                      <Terminal className="w-4 h-4 text-neutral-500" />
                      <h3 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                        Dev Script
                      </h3>
                    </div>
                    {!isEditingDevScript && (
                      <button
                        type="button"
                        onClick={handleStartEditingDevScript}
                        disabled={updateDevScriptMutation.isPending}
                        className={cn(
                          "inline-flex items-center gap-1 rounded-md border border-neutral-300 px-3 py-1 text-xs font-medium text-neutral-700 disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300",
                          !updateDevScriptMutation.isPending &&
                            "hover:bg-neutral-100 dark:hover:bg-neutral-900",
                        )}
                      >
                        {environment.devScript && environment.devScript.length > 0
                          ? "Edit"
                          : "Add"}
                      </button>
                    )}
                  </div>
                  {isEditingDevScript ? (
                    <div className="space-y-2">
                      <ScriptTextareaField
                        description={SCRIPT_COPY.dev.description}
                        subtitle={SCRIPT_COPY.dev.subtitle}
                        value={devScriptDraft}
                        onChange={(next) => setDevScriptDraft(next)}
                        placeholder={SCRIPT_COPY.dev.placeholder}
                        disabled={updateDevScriptMutation.isPending}
                        minHeightClassName="min-h-[130px]"
                      />
                      <div className="flex gap-2">
                        <button
                          type="button"
                          onClick={handleSaveDevScript}
                          disabled={updateDevScriptMutation.isPending}
                          className="inline-flex h-8 items-center justify-center rounded-md bg-neutral-900 px-4 text-sm font-medium text-white hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-60 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                        >
                          {updateDevScriptMutation.isPending ? "Saving..." : "Save"}
                        </button>
                        <button
                          type="button"
                          onClick={handleCancelDevScript}
                          disabled={updateDevScriptMutation.isPending}
                          className={cn(
                            "inline-flex h-8 items-center justify-center rounded-md border border-neutral-300 px-4 text-sm font-medium text-neutral-700 disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300",
                            !updateDevScriptMutation.isPending &&
                              "hover:bg-neutral-100 dark:hover:bg-neutral-900",
                          )}
                        >
                          Cancel
                        </button>
                      </div>
                    </div>
                  ) : environment.devScript && environment.devScript.length > 0 ? (
                    <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-3 dark:bg-neutral-950">
                      <pre className="whitespace-pre-wrap break-words font-mono text-sm text-green-400">
                        {environment.devScript}
                      </pre>
                    </div>
                  ) : (
                    <p className="text-sm text-neutral-500 dark:text-neutral-500">
                      No dev script configured.
                    </p>
                  )}
                </div>

                <div>
                  <div className="mb-2 flex items-start justify-between gap-2">
                    <div className="flex items-center gap-2">
                      <Code className="w-4 h-4 text-neutral-500" />
                      <h3 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                        Maintenance Script
                      </h3>
                    </div>
                    {!isEditingMaintenanceScript && (
                      <button
                        type="button"
                        onClick={handleStartEditingMaintenanceScript}
                        disabled={updateMaintenanceScriptMutation.isPending}
                        className={cn(
                          "inline-flex items-center gap-1 rounded-md border border-neutral-300 px-3 py-1 text-xs font-medium text-neutral-700 disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300",
                          !updateMaintenanceScriptMutation.isPending &&
                            "hover:bg-neutral-100 dark:hover:bg-neutral-900",
                        )}
                      >
                        {environment.maintenanceScript &&
                        environment.maintenanceScript.length > 0
                          ? "Edit"
                          : "Add"}
                      </button>
                    )}
                  </div>
                  {isEditingMaintenanceScript ? (
                    <div className="space-y-2">
                      <ScriptTextareaField
                        description={SCRIPT_COPY.maintenance.description}
                        subtitle={SCRIPT_COPY.maintenance.subtitle}
                        value={maintenanceScriptDraft}
                        onChange={(next) => setMaintenanceScriptDraft(next)}
                        placeholder={SCRIPT_COPY.maintenance.placeholder}
                        disabled={updateMaintenanceScriptMutation.isPending}
                        descriptionClassName="mb-3"
                        minHeightClassName="min-h-[114px]"
                      />
                      <div className="flex gap-2">
                        <button
                          type="button"
                          onClick={handleSaveMaintenanceScript}
                          disabled={updateMaintenanceScriptMutation.isPending}
                          className="inline-flex h-8 items-center justify-center rounded-md bg-neutral-900 px-4 text-sm font-medium text-white hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-60 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                        >
                          {updateMaintenanceScriptMutation.isPending
                            ? "Saving..."
                            : "Save"}
                        </button>
                        <button
                          type="button"
                          onClick={handleCancelMaintenanceScript}
                          disabled={updateMaintenanceScriptMutation.isPending}
                          className={cn(
                            "inline-flex h-8 items-center justify-center rounded-md border border-neutral-300 px-4 text-sm font-medium text-neutral-700 disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300",
                            !updateMaintenanceScriptMutation.isPending &&
                              "hover:bg-neutral-100 dark:hover:bg-neutral-900",
                          )}
                        >
                          Cancel
                        </button>
                      </div>
                    </div>
                  ) : environment.maintenanceScript &&
                    environment.maintenanceScript.length > 0 ? (
                    <div className="rounded-lg border border-neutral-800 bg-neutral-900 p-3 dark:bg-neutral-950">
                      <pre className="whitespace-pre-wrap break-words font-mono text-sm text-green-400">
                        {environment.maintenanceScript}
                      </pre>
                    </div>
                  ) : (
                    <p className="text-sm text-neutral-500 dark:text-neutral-500">
                      No maintenance script configured.
                    </p>
                  )}
                </div>
              </div>

              {/* Exposed Ports */}
              <div>
                <div className="mb-3 flex items-center gap-2">
                  <Package className="w-4 h-4 text-neutral-500" />
                  <h3 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                    Exposed Ports
                  </h3>
                </div>
                {isEditingPorts ? (
                  <div className="space-y-3">
                    <div className="flex flex-wrap gap-2">
                      {portsDraft.length > 0 ? (
                        portsDraft.map((port) => (
                          <span
                            key={port}
                            className="inline-flex items-center rounded-full bg-neutral-100 dark:bg-neutral-900 px-3 py-1 text-sm text-neutral-700 dark:text-neutral-300"
                          >
                            {port}
                            <button
                              type="button"
                              onClick={() => handleRemovePort(port)}
                              className="ml-2 text-neutral-500 hover:text-neutral-800 dark:text-neutral-500 dark:hover:text-neutral-200"
                              aria-label={`Remove port ${port}`}
                            >
                              <X className="w-3 h-3" />
                            </button>
                          </span>
                        ))
                      ) : (
                        <span className="text-sm text-neutral-500 dark:text-neutral-500">
                          No ports selected.
                        </span>
                      )}
                    </div>
                    <div className="flex items-center gap-2">
                      <input
                        type="number"
                        value={portInput}
                        onChange={(event) => setPortInput(event.target.value)}
                        onKeyDown={handlePortInputKeyDown}
                        placeholder="Add port"
                        className="h-7 w-28 rounded-md border border-neutral-300 px-3 text-sm text-neutral-900 focus:outline-none focus:ring-2 focus:ring-neutral-300 dark:border-neutral-700 dark:bg-neutral-950 dark:text-neutral-100 dark:focus:ring-neutral-700 [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none"
                      />
                      <button
                        type="button"
                        onClick={handleAddPort}
                        className="inline-flex h-7 items-center gap-1 rounded-md border border-neutral-300 px-3 text-sm font-medium text-neutral-700 hover:bg-neutral-100 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-900"
                      >
                        <Plus className="w-3 h-3" />
                        Add port
                      </button>
                    </div>
                    <div className="flex gap-2">
                      <button
                        type="button"
                        onClick={handleSavePorts}
                        disabled={
                          updatePortsMutation.isPending || !hasPortChanges
                        }
                        className="inline-flex h-7 items-center justify-center rounded-md bg-neutral-900 px-4 text-sm font-medium text-white hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-60 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                      >
                        {updatePortsMutation.isPending ? "Saving..." : "Save"}
                      </button>
                      <button
                        type="button"
                        onClick={handleCancelPorts}
                        disabled={updatePortsMutation.isPending}
                        className="inline-flex h-7 items-center justify-center rounded-md border border-neutral-300 px-4 text-sm font-medium text-neutral-700 hover:bg-neutral-100 disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-900"
                      >
                        Cancel
                      </button>
                    </div>
                    {portsError && (
                      <p className="text-xs text-red-500">{portsError}</p>
                    )}
                  </div>
                ) : (
                  <div className="space-y-3">
                    {environment.exposedPorts &&
                    environment.exposedPorts.length > 0 ? (
                      <div className="flex flex-wrap gap-2">
                        {environment.exposedPorts.map((port: number) => (
                          <span
                            key={port}
                            className="inline-flex items-center rounded-full bg-neutral-100 px-3 py-1 text-sm text-neutral-700 dark:bg-neutral-900 dark:text-neutral-300"
                          >
                            {port}
                          </span>
                        ))}
                        <button
                          type="button"
                          onClick={handleStartEditingPorts}
                          className="inline-flex h-7 items-center gap-1 rounded-md border border-neutral-300 px-3 text-sm font-medium text-neutral-700 hover:bg-neutral-100 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-900"
                        >
                          <Plus className="w-3 h-3" />
                          Add port
                        </button>
                      </div>
                    ) : (
                      <div className="flex flex-col items-start gap-2">
                        <span className="text-sm text-neutral-500 dark:text-neutral-500">
                          No ports configured.
                        </span>
                        <button
                          type="button"
                          onClick={handleStartEditingPorts}
                          className="inline-flex h-7 items-center gap-1 rounded-md border border-neutral-300 px-3 text-sm font-medium text-neutral-700 hover:bg-neutral-100 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-900"
                        >
                          <Plus className="w-3 h-3" />
                          Add port
                        </button>
                      </div>
                    )}
                  </div>
                )}
              </div>

              {/* Snapshot Versions */}
              <div className="pt-4 border-t border-neutral-200 dark:border-neutral-800">
                <div className="flex items-center justify-between mb-3">
                  <h3 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                    Snapshot Versions
                  </h3>
                  <Tooltip>
                    <TooltipTrigger asChild>
                      <button
                        type="button"
                        onClick={handleStartSnapshotVersion}
                        disabled={isSnapshotPending || isModifyPending}
                        className={cn(
                          "inline-flex items-center gap-1 rounded-md border border-neutral-300 px-3 py-1 text-xs font-medium text-neutral-700 transition-colors disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300",
                          !(isSnapshotPending || isModifyPending) &&
                            "hover:bg-neutral-100 dark:hover:bg-neutral-900",
                        )}
                      >
                        {isSnapshotPending ? (
                          <>
                            <Loader2 className="h-3 w-3 animate-spin" />
                            Launching…
                          </>
                        ) : (
                          "New snapshot version"
                        )}
                      </button>
                    </TooltipTrigger>
                    <TooltipContent className="max-w-xs text-xs leading-snug">
                      {sandboxTooltipDescription}
                    </TooltipContent>
                  </Tooltip>
                </div>
                <div className="space-y-2">
                  {snapshotVersions.length === 0 ? (
                    <p className="text-sm text-neutral-500 dark:text-neutral-500">
                      No snapshot versions yet.
                    </p>
                  ) : (
                    snapshotVersions.map((version) => (
                      <div
                        key={version._id}
                        className="rounded-md border border-neutral-200 p-3 dark:border-neutral-800"
                      >
                        <div className="flex items-center justify-between gap-3">
                          <div>
                            <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                              Version {version.version}
                              {version.isActive && (
                                <span className="ml-2 inline-flex items-center rounded-full bg-green-100 px-2 py-0.5 text-[10px] font-semibold text-green-700 dark:bg-green-900 dark:text-green-100">
                                  Active
                                </span>
                              )}
                            </p>
                            <p className="text-xs text-neutral-500 dark:text-neutral-500">
                              Snapshot ID: {version.morphSnapshotId}
                            </p>
                          </div>
                          <div className="flex items-center gap-2">
                            {!version.isActive && (
                              <button
                                type="button"
                                onClick={() =>
                                  handleActivateSnapshot(version._id)
                                }
                                disabled={
                                  activateSnapshotMutation.isPending &&
                                  activatingVersionId === String(version._id)
                                }
                                className="inline-flex items-center rounded-md border border-neutral-300 px-3 py-1 text-xs font-medium text-neutral-700 hover:bg-neutral-100 disabled:opacity-60 disabled:cursor-not-allowed dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-900"
                              >
                                {activateSnapshotMutation.isPending &&
                                activatingVersionId === String(version._id)
                                  ? "Activating..."
                                  : "Activate"}
                              </button>
                            )}
                            <button
                              type="button"
                              onClick={() =>
                                handleDeleteSnapshotVersion(version._id)
                              }
                              disabled={
                                version.isActive ||
                                deletingVersionId === String(version._id)
                              }
                              title={
                                version.isActive
                                  ? "Cannot delete the active snapshot version"
                                  : undefined
                              }
                              className="inline-flex items-center gap-1 rounded-md border border-neutral-300 px-3 py-1 text-xs font-medium text-neutral-700 hover:bg-neutral-100 disabled:cursor-not-allowed disabled:opacity-60 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-900"
                            >
                              {deletingVersionId === String(version._id) ? (
                                <>
                                  <Loader2 className="h-3 w-3 animate-spin" />
                                  Deleting…
                                </>
                              ) : (
                                <>
                                  <Trash2 className="h-3 w-3" />
                                  Delete
                                </>
                              )}
                            </button>
                          </div>
                        </div>
                        <div className="mt-2 space-y-1 text-xs text-neutral-500 dark:text-neutral-500">
                          <p>
                            Created{" "}
                            {formatDistanceToNow(new Date(version.createdAt), {
                              addSuffix: true,
                            })}
                          </p>
                          <p>Created by {version.createdByUserId}</p>
                          {version.label && <p>Label: {version.label}</p>}
                        </div>
                      </div>
                    ))
                  )}
                </div>
              </div>
            </div>

            {/* Danger Zone */}
            <div className="pt-6 border-t border-neutral-200 dark:border-neutral-800">
              <h3 className="text-sm font-medium text-red-600 dark:text-red-400 mb-3">
                Danger Zone
              </h3>
              <button
                onClick={handleDelete}
                disabled={isDeleting}
                className="inline-flex items-center gap-2 rounded-md border border-red-300 dark:border-red-800 bg-white dark:bg-neutral-950 px-4 py-2 text-sm font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-950/20 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <Trash2 className="w-4 h-4" />
                {isDeleting ? "Deleting..." : "Delete Environment"}
              </button>
            </div>
          </div>
        ) : (
          <div className="text-center py-12">
            <div className="w-16 h-16 mx-auto mb-4 rounded-lg bg-neutral-100 dark:bg-neutral-900 flex items-center justify-center">
              <Server className="w-8 h-8 text-neutral-400 dark:text-neutral-600" />
            </div>
            <h3 className="text-lg font-medium text-neutral-900 dark:text-neutral-100 mb-2">
              Environment not found
            </h3>
            <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-6">
              The environment you're looking for doesn't exist or has been
              deleted.
            </p>
            <Link
              to="/$teamSlugOrId/environments"
              params={{ teamSlugOrId }}
              search={{
                step: undefined,
                selectedRepos: undefined,
                connectionLogin: undefined,
                repoSearch: undefined,
                instanceId: undefined,
              }}
              className="inline-flex items-center gap-2 rounded-md bg-neutral-900 text-white px-4 py-2 text-sm hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
            >
              <ArrowLeft className="w-4 h-4" />
              Back to Environments
            </Link>
          </div>
        )}
      </div>
    </FloatingPane>
  );
}
