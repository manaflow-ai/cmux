"use client";

import { useCallback, useState } from "react";
import {
  ChevronDown,
  ExternalLink,
  Loader2,
  Play,
  Plus,
  RefreshCw,
  Trash2,
  X,
  Image as ImageIcon,
  AlertCircle,
  CheckCircle2,
  Clock,
  FileText,
} from "lucide-react";
import Link from "next/link";
import clsx from "clsx";
import {
  QueryClient,
  QueryClientProvider,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import {
  getApiPreviewTestJobs,
  postApiPreviewTestJobs,
  postApiPreviewTestJobsByPreviewRunIdDispatch,
  deleteApiPreviewTestJobsByPreviewRunId,
} from "@cmux/www-openapi-client";

type TeamOption = {
  slugOrId: string;
  displayName: string;
};

type ScreenshotImage = {
  storageId: string;
  mimeType: string;
  fileName?: string | null;
  description?: string | null;
  url?: string | null;
};

type ScreenshotSet = {
  _id: string;
  status: "completed" | "failed" | "skipped";
  hasUiChanges?: boolean | null;
  capturedAt: number;
  error?: string | null;
  images: ScreenshotImage[];
};

type TestJob = {
  _id: string;
  prNumber: number;
  prUrl: string;
  prTitle?: string | null;
  repoFullName: string;
  headSha: string;
  status: "pending" | "running" | "completed" | "failed" | "skipped";
  stateReason?: string | null;
  taskRunId?: string | null;
  createdAt: number;
  updatedAt: number;
  dispatchedAt?: number | null;
  startedAt?: number | null;
  completedAt?: number | null;
  configRepoFullName?: string | null;
  screenshotSet?: ScreenshotSet | null;
  taskId?: string | null;
};

type PreviewTestDashboardProps = {
  selectedTeamSlugOrId: string;
  teamOptions: TeamOption[];
};

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 5000,
      refetchInterval: 10000, // Poll every 10 seconds for status updates
    },
  },
});

function PreviewTestDashboardInner({
  selectedTeamSlugOrId,
  teamOptions,
}: PreviewTestDashboardProps) {
  const [prUrls, setPrUrls] = useState("");
  const [selectedTeam, setSelectedTeam] = useState(selectedTeamSlugOrId);
  const [expandedJobs, setExpandedJobs] = useState<Set<string>>(new Set());
  const [error, setError] = useState<string | null>(null);
  const qc = useQueryClient();

  // Fetch test jobs
  const { data: jobsData, isLoading: isLoadingJobs } = useQuery({
    queryKey: ["preview-test-jobs", selectedTeam],
    queryFn: async () => {
      const response = await getApiPreviewTestJobs({
        query: { teamSlugOrId: selectedTeam },
      });
      if (response.error) {
        throw new Error("Failed to fetch test jobs");
      }
      return response.data;
    },
    enabled: Boolean(selectedTeam),
  });

  const jobs = (jobsData?.jobs ?? []) as TestJob[];

  // Create test job mutation
  const createJobMutation = useMutation({
    mutationFn: async (prUrl: string) => {
      const response = await postApiPreviewTestJobs({
        body: {
          teamSlugOrId: selectedTeam,
          prUrl,
        },
      });
      if (response.error) {
        throw new Error(
          (response.error as { error?: string }).error ?? "Failed to create test job"
        );
      }
      return response.data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["preview-test-jobs", selectedTeam] });
    },
    onError: (error) => {
      setError(error.message);
    },
  });

  // Dispatch test job mutation
  const dispatchJobMutation = useMutation({
    mutationFn: async (previewRunId: string) => {
      const response = await postApiPreviewTestJobsByPreviewRunIdDispatch({
        path: { previewRunId },
        query: { teamSlugOrId: selectedTeam },
      });
      if (response.error) {
        throw new Error("Failed to dispatch test job");
      }
      return response.data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["preview-test-jobs", selectedTeam] });
    },
    onError: (error) => {
      setError(error.message);
    },
  });

  // Delete test job mutation
  const deleteJobMutation = useMutation({
    mutationFn: async (previewRunId: string) => {
      const response = await deleteApiPreviewTestJobsByPreviewRunId({
        path: { previewRunId },
        query: { teamSlugOrId: selectedTeam },
      });
      if (response.error) {
        throw new Error("Failed to delete test job");
      }
      return response.data;
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["preview-test-jobs", selectedTeam] });
    },
    onError: (error) => {
      setError(error.message);
    },
  });

  const handleCreateJobs = useCallback(async () => {
    setError(null);
    const urls = prUrls
      .split("\n")
      .map((url) => url.trim())
      .filter((url) => url.length > 0);

    if (urls.length === 0) {
      setError("Please enter at least one PR URL");
      return;
    }

    for (const url of urls) {
      await createJobMutation.mutateAsync(url);
    }
    setPrUrls("");
  }, [prUrls, createJobMutation]);

  const handleDispatchJob = useCallback(
    async (previewRunId: string) => {
      setError(null);
      await dispatchJobMutation.mutateAsync(previewRunId);
    },
    [dispatchJobMutation]
  );

  const handleDeleteJob = useCallback(
    async (previewRunId: string) => {
      setError(null);
      await deleteJobMutation.mutateAsync(previewRunId);
    },
    [deleteJobMutation]
  );

  const handleDispatchAll = useCallback(async () => {
    setError(null);
    const pendingJobs = jobs.filter((job) => job.status === "pending");
    for (const job of pendingJobs) {
      await dispatchJobMutation.mutateAsync(job._id);
    }
  }, [jobs, dispatchJobMutation]);

  const toggleJobExpanded = useCallback((jobId: string) => {
    setExpandedJobs((prev) => {
      const next = new Set(prev);
      if (next.has(jobId)) {
        next.delete(jobId);
      } else {
        next.add(jobId);
      }
      return next;
    });
  }, []);

  const getStatusIcon = (status: TestJob["status"]) => {
    switch (status) {
      case "pending":
        return <Clock className="h-4 w-4 text-neutral-400" />;
      case "running":
        return <Loader2 className="h-4 w-4 text-blue-400 animate-spin" />;
      case "completed":
        return <CheckCircle2 className="h-4 w-4 text-green-400" />;
      case "failed":
        return <AlertCircle className="h-4 w-4 text-red-400" />;
      case "skipped":
        return <X className="h-4 w-4 text-neutral-500" />;
    }
  };

  const getStatusText = (status: TestJob["status"]) => {
    switch (status) {
      case "pending":
        return "Pending";
      case "running":
        return "Running";
      case "completed":
        return "Completed";
      case "failed":
        return "Failed";
      case "skipped":
        return "Skipped";
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Preview.new Testing</h1>
          <p className="mt-1 text-sm text-neutral-400">
            Test preview jobs without GitHub integration. Screenshots and captions
            will be generated but no comments will be posted.
          </p>
        </div>
        <Link href="/preview">
          <Button variant="outline" size="sm">
            Back to Preview
          </Button>
        </Link>
      </div>

      {/* Team selector */}
      {teamOptions.length > 1 && (
        <div className="flex items-center gap-2">
          <label className="text-sm text-neutral-400">Team:</label>
          <select
            value={selectedTeam}
            onChange={(e) => setSelectedTeam(e.target.value)}
            className="rounded-md border border-neutral-700 bg-neutral-800 px-3 py-1.5 text-sm text-white focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          >
            {teamOptions.map((team) => (
              <option key={team.slugOrId} value={team.slugOrId}>
                {team.displayName}
              </option>
            ))}
          </select>
        </div>
      )}

      {/* PR URL input */}
      <div className="rounded-lg border border-neutral-800 bg-neutral-900/50 p-4">
        <label className="mb-2 block text-sm font-medium text-white">
          PR URLs (one per line)
        </label>
        <textarea
          value={prUrls}
          onChange={(e) => setPrUrls(e.target.value)}
          placeholder="https://github.com/owner/repo/pull/123&#10;https://github.com/owner/repo/pull/456"
          className="h-32 w-full rounded-md border border-neutral-700 bg-neutral-800 px-3 py-2 text-sm text-white placeholder:text-neutral-500 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
        />
        <div className="mt-3 flex items-center gap-3">
          <Button
            onClick={handleCreateJobs}
            disabled={createJobMutation.isPending || !prUrls.trim()}
            className="gap-2"
          >
            {createJobMutation.isPending ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <Plus className="h-4 w-4" />
            )}
            Add Jobs
          </Button>
          {jobs.some((job) => job.status === "pending") && (
            <Button
              onClick={handleDispatchAll}
              disabled={dispatchJobMutation.isPending}
              variant="outline"
              className="gap-2"
            >
              {dispatchJobMutation.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Play className="h-4 w-4" />
              )}
              Start All Pending
            </Button>
          )}
          <Button
            onClick={() =>
              qc.invalidateQueries({
                queryKey: ["preview-test-jobs", selectedTeam],
              })
            }
            variant="ghost"
            size="icon"
            className="ml-auto"
          >
            <RefreshCw
              className={clsx("h-4 w-4", isLoadingJobs && "animate-spin")}
            />
          </Button>
        </div>
      </div>

      {/* Error display */}
      {error && (
        <div className="flex items-center gap-2 rounded-lg border border-red-800 bg-red-900/20 px-4 py-3 text-sm text-red-300">
          <AlertCircle className="h-4 w-4" />
          {error}
          <button
            onClick={() => setError(null)}
            className="ml-auto hover:text-white"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
      )}

      {/* Jobs list */}
      <div className="space-y-3">
        <h2 className="text-lg font-semibold text-white">
          Test Jobs ({jobs.length})
        </h2>

        {isLoadingJobs ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="h-6 w-6 animate-spin text-neutral-400" />
          </div>
        ) : jobs.length === 0 ? (
          <div className="rounded-lg border border-neutral-800 bg-neutral-900/30 py-12 text-center">
            <ImageIcon className="mx-auto h-12 w-12 text-neutral-600" />
            <p className="mt-4 text-neutral-400">No test jobs yet</p>
            <p className="mt-1 text-sm text-neutral-500">
              Add PR URLs above to create test jobs
            </p>
          </div>
        ) : (
          <div className="space-y-2">
            {jobs.map((job) => (
              <div
                key={job._id}
                className="rounded-lg border border-neutral-800 bg-neutral-900/50 overflow-hidden"
              >
                {/* Job header */}
                <div
                  className="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-neutral-800/50"
                  onClick={() => toggleJobExpanded(job._id)}
                >
                  <ChevronDown
                    className={clsx(
                      "h-4 w-4 text-neutral-500 transition-transform",
                      !expandedJobs.has(job._id) && "-rotate-90"
                    )}
                  />
                  {getStatusIcon(job.status)}
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="font-medium text-white">
                        {job.repoFullName}
                      </span>
                      <span className="text-neutral-400">#{job.prNumber}</span>
                    </div>
                    {job.prTitle && (
                      <p className="truncate text-sm text-neutral-500">
                        {job.prTitle}
                      </p>
                    )}
                  </div>
                  <span
                    className={clsx(
                      "rounded-full px-2 py-0.5 text-xs font-medium",
                      job.status === "pending" &&
                        "bg-neutral-700 text-neutral-300",
                      job.status === "running" && "bg-blue-900 text-blue-300",
                      job.status === "completed" &&
                        "bg-green-900 text-green-300",
                      job.status === "failed" && "bg-red-900 text-red-300",
                      job.status === "skipped" &&
                        "bg-neutral-700 text-neutral-400"
                    )}
                  >
                    {getStatusText(job.status)}
                  </span>
                  <div
                    className="flex items-center gap-1"
                    onClick={(e) => e.stopPropagation()}
                  >
                    {job.status === "pending" && (
                      <Button
                        onClick={() => handleDispatchJob(job._id)}
                        disabled={dispatchJobMutation.isPending}
                        size="sm"
                        className="gap-1"
                      >
                        <Play className="h-3 w-3" />
                        Start
                      </Button>
                    )}
                    <a
                      href={job.prUrl}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="rounded p-1.5 text-neutral-400 hover:bg-neutral-700 hover:text-white"
                    >
                      <ExternalLink className="h-4 w-4" />
                    </a>
                    <button
                      onClick={() => handleDeleteJob(job._id)}
                      disabled={deleteJobMutation.isPending}
                      className="rounded p-1.5 text-neutral-400 hover:bg-red-900/50 hover:text-red-300"
                    >
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                </div>

                {/* Expanded content */}
                {expandedJobs.has(job._id) && (
                  <div className="border-t border-neutral-800 px-4 py-4">
                    {/* Metadata */}
                    <div className="mb-4 grid grid-cols-2 gap-4 text-sm">
                      <div>
                        <span className="text-neutral-500">Created:</span>{" "}
                        <span className="text-neutral-300">
                          {new Date(job.createdAt).toLocaleString()}
                        </span>
                      </div>
                      {job.dispatchedAt && (
                        <div>
                          <span className="text-neutral-500">Dispatched:</span>{" "}
                          <span className="text-neutral-300">
                            {new Date(job.dispatchedAt).toLocaleString()}
                          </span>
                        </div>
                      )}
                      {job.completedAt && (
                        <div>
                          <span className="text-neutral-500">Completed:</span>{" "}
                          <span className="text-neutral-300">
                            {new Date(job.completedAt).toLocaleString()}
                          </span>
                        </div>
                      )}
                      <div>
                        <span className="text-neutral-500">Head SHA:</span>{" "}
                        <span className="font-mono text-neutral-300">
                          {job.headSha.substring(0, 8)}
                        </span>
                      </div>
                    </div>

                    {/* Trajectory link */}
                    {job.taskId && job.taskRunId && (
                      <div className="mb-4">
                        <Link
                          href={`/${selectedTeam}/task/${job.taskId}/run/${job.taskRunId}`}
                          className="inline-flex items-center gap-2 rounded-md bg-neutral-800 px-3 py-1.5 text-sm text-neutral-300 hover:bg-neutral-700 hover:text-white"
                        >
                          <FileText className="h-4 w-4" />
                          View Trajectory
                          <ExternalLink className="h-3 w-3" />
                        </Link>
                      </div>
                    )}

                    {/* Screenshots */}
                    {job.screenshotSet ? (
                      <div>
                        <h4 className="mb-3 text-sm font-medium text-white">
                          Screenshots ({job.screenshotSet.images.length})
                          {job.screenshotSet.hasUiChanges === false && (
                            <span className="ml-2 text-neutral-500">
                              - No UI changes detected
                            </span>
                          )}
                        </h4>
                        {job.screenshotSet.error && (
                          <div className="mb-3 rounded-md bg-red-900/20 px-3 py-2 text-sm text-red-300">
                            Error: {job.screenshotSet.error}
                          </div>
                        )}
                        {job.screenshotSet.images.length > 0 ? (
                          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
                            {job.screenshotSet.images.map((image, index) => (
                              <div
                                key={image.storageId}
                                className="overflow-hidden rounded-lg border border-neutral-700 bg-neutral-800"
                              >
                                {image.url ? (
                                  <a
                                    href={image.url}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                  >
                                    <img
                                      src={image.url}
                                      alt={
                                        image.description ??
                                        `Screenshot ${index + 1}`
                                      }
                                      className="aspect-video w-full object-cover hover:opacity-90"
                                    />
                                  </a>
                                ) : (
                                  <div className="flex aspect-video items-center justify-center bg-neutral-900">
                                    <ImageIcon className="h-8 w-8 text-neutral-600" />
                                  </div>
                                )}
                                {image.description && (
                                  <div className="px-3 py-2">
                                    <p className="text-sm text-neutral-300">
                                      {image.description}
                                    </p>
                                    {image.fileName && (
                                      <p className="mt-1 text-xs text-neutral-500">
                                        {image.fileName}
                                      </p>
                                    )}
                                  </div>
                                )}
                              </div>
                            ))}
                          </div>
                        ) : (
                          <p className="text-sm text-neutral-500">
                            No screenshots captured
                          </p>
                        )}
                      </div>
                    ) : job.status === "running" ? (
                      <div className="flex items-center gap-2 text-sm text-neutral-400">
                        <Loader2 className="h-4 w-4 animate-spin" />
                        Capturing screenshots...
                      </div>
                    ) : job.status === "pending" ? (
                      <p className="text-sm text-neutral-500">
                        Start the job to capture screenshots
                      </p>
                    ) : (
                      <p className="text-sm text-neutral-500">
                        No screenshots available
                      </p>
                    )}
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

export function PreviewTestDashboard(props: PreviewTestDashboardProps) {
  return (
    <QueryClientProvider client={queryClient}>
      <PreviewTestDashboardInner {...props} />
    </QueryClientProvider>
  );
}
