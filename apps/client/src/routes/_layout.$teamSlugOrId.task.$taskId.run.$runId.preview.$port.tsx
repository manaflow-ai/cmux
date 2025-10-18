import { DevPreviewTerminal } from "@/components/dev-preview-terminal";
import { ElectronPreviewBrowser } from "@/components/electron-preview-browser";
import { Button } from "@/components/ui/button";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { getTaskRunPreviewPersistKey } from "@/lib/persistent-webview-keys";
import { api } from "@cmux/convex/api";
import { typedZid } from "@cmux/shared/utils/typed-zid";
import { createFileRoute } from "@tanstack/react-router";
import clsx from "clsx";
import { useQuery } from "convex/react";
import { useEffect, useMemo, useRef, useState } from "react";
import { AlertTriangle, ExternalLink, TerminalSquare } from "lucide-react";
import z from "zod";

const paramsSchema = z.object({
  taskId: typedZid("tasks"),
  runId: typedZid("taskRuns"),
  port: z.string(),
});

const DEV_TERMINAL_PORT = 39_383;

type NetworkingEntry = {
  port: number;
  status: string;
  url: string;
};

type TaskRun = (typeof api.taskRuns.getByTask._returnType)[number];

function getOrigin(rawUrl: string | null | undefined): string | null {
  if (!rawUrl) {
    return null;
  }
  try {
    const parsed = new URL(rawUrl);
    return `${parsed.protocol}//${parsed.host}`;
  } catch {
    return null;
  }
}

function deriveServiceOrigin(
  rawUrl: string | null | undefined,
  port: number,
): string | null {
  if (!rawUrl) {
    return null;
  }
  try {
    const parsed = new URL(rawUrl);
    let changed = false;

    if (/^port-\d+-/.test(parsed.hostname)) {
      const replacement = parsed.hostname.replace(
        /^port-\d+-/,
        `port-${port}-`,
      );
      if (replacement !== parsed.hostname) {
        parsed.hostname = replacement;
        changed = true;
      }
    } else if (parsed.port) {
      if (parsed.port !== String(port)) {
        parsed.port = String(port);
        changed = true;
      }
    } else {
      parsed.port = String(port);
      changed = true;
    }

    if (!changed) {
      return null;
    }

    parsed.pathname = "/";
    parsed.search = "";
    parsed.hash = "";
    return `${parsed.protocol}//${parsed.host}`;
  } catch {
    return null;
  }
}

export const Route = createFileRoute(
  "/_layout/$teamSlugOrId/task/$taskId/run/$runId/preview/$port",
)({
  component: PreviewPage,
  params: {
    parse: paramsSchema.parse,
    stringify: (params) => {
      return {
        taskId: params.taskId,
        runId: params.runId,
        port: params.port,
      };
    },
  },
});

function PreviewPage() {
  const { taskId, teamSlugOrId, runId, port } = Route.useParams();

  const taskRuns = useQuery(api.taskRuns.getByTask, {
    teamSlugOrId,
    taskId,
  });

  const selectedRun = useMemo<TaskRun | undefined>(() => {
    return taskRuns?.find((run) => run._id === runId);
  }, [runId, taskRuns]);

  const previewUrl = useMemo(() => {
    if (!selectedRun?.networking) return null;
    const portNum = Number.parseInt(port, 10);
    const service = selectedRun.networking.find(
      (entry) => entry.port === portNum && entry.status === "running",
    );
    return service?.url ?? null;
  }, [selectedRun, port]);

  const persistKey = useMemo(() => {
    return getTaskRunPreviewPersistKey(runId, port);
  }, [runId, port]);

  const previewDescriptor = useMemo(() => {
    if (previewUrl) {
      try {
        return new URL(previewUrl).host;
      } catch {
        return previewUrl;
      }
    }
    return `Port ${port}`;
  }, [previewUrl, port]);

  const runningServices = useMemo<NetworkingEntry[]>(() => {
    return (
      selectedRun?.networking?.filter(
        (service: NetworkingEntry) => service.status === "running",
      ) ?? []
    );
  }, [selectedRun]);

  const devTerminalEndpoint = useMemo(() => {
    const explicit = runningServices.find(
      (service) => service.port === DEV_TERMINAL_PORT,
    );
    if (explicit?.url) {
      const origin = getOrigin(explicit.url);
      if (origin) return origin;
    }

    const fallbackSources = [
      previewUrl,
      selectedRun?.vscode?.url ?? null,
      runningServices[0]?.url ?? null,
    ];

    for (const candidate of fallbackSources) {
      const derived = deriveServiceOrigin(candidate, DEV_TERMINAL_PORT);
      if (derived) {
        return derived;
      }
    }

    return null;
  }, [previewUrl, runningServices, selectedRun]);

  const devErrorMessage = selectedRun?.environmentError?.devError ?? null;
  const hasDevError = Boolean(devErrorMessage);

  const [isTerminalOpen, setTerminalOpen] = useState(false);
  const autoOpenedBecauseOfErrorRef = useRef(false);

  useEffect(() => {
    if (hasDevError) {
      if (!autoOpenedBecauseOfErrorRef.current) {
        setTerminalOpen(true);
        autoOpenedBecauseOfErrorRef.current = true;
      }
    } else {
      autoOpenedBecauseOfErrorRef.current = false;
    }
  }, [hasDevError]);

  const openPreviewExternally = () => {
    if (!previewUrl) return;
    if (typeof window === "undefined") return;
    window.open(previewUrl, "_blank", "noreferrer,noopener");
  };

  const availablePorts = useMemo(() => {
    return runningServices.map((service) => service.port);
  }, [runningServices]);

  const toggleButtonClassName = clsx(
    "cursor-pointer px-3",
    "border-neutral-200 text-neutral-600 hover:bg-neutral-100 dark:border-neutral-700 dark:text-neutral-300 dark:hover:bg-neutral-800",
    isTerminalOpen &&
      "border-neutral-700 bg-neutral-900 text-neutral-100 hover:bg-neutral-800 dark:border-neutral-700 dark:bg-neutral-800",
    hasDevError && !isTerminalOpen &&
      "ring-1 ring-rose-400/60 ring-offset-1 ring-offset-white dark:ring-offset-neutral-950",
    !devTerminalEndpoint && "cursor-not-allowed opacity-50",
  );

  const openButtonClassName = clsx(
    "cursor-pointer border-neutral-200 text-neutral-700 hover:bg-neutral-100 dark:border-neutral-700 dark:text-neutral-200 dark:hover:bg-neutral-800",
    !previewUrl && "cursor-not-allowed opacity-50",
  );

  return (
    <div className="flex h-full flex-col bg-white dark:bg-neutral-950">
      <div className="flex flex-col gap-3 border-b border-neutral-200/80 px-4 py-3 md:flex-row md:items-center md:justify-between dark:border-neutral-800/60">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-3">
          <div>
            <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-neutral-500 dark:text-neutral-400">
              Preview
            </p>
            <p className="text-sm font-medium text-neutral-800 dark:text-neutral-100">
              {previewDescriptor}
            </p>
          </div>
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={!previewUrl}
            onClick={openPreviewExternally}
            className={openButtonClassName}
          >
            <ExternalLink className="size-3.5" />
            Open in browser
          </Button>
        </div>
        <div className="flex items-center gap-2">
          {devErrorMessage ? (
            <Tooltip>
              <TooltipTrigger asChild>
                <div className="inline-flex items-center gap-1 rounded-full border border-rose-500/30 bg-rose-500/10 px-2 py-1 text-[11px] font-medium text-rose-600 dark:border-rose-400/30 dark:bg-rose-400/15 dark:text-rose-300">
                  <AlertTriangle className="size-3" />
                  Dev script error
                </div>
              </TooltipTrigger>
              <TooltipContent side="bottom" align="end" className="max-w-xs text-xs leading-relaxed">
                {devErrorMessage}
              </TooltipContent>
            </Tooltip>
          ) : null}
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={!devTerminalEndpoint}
            onClick={() => setTerminalOpen((prev) => !prev)}
            className={toggleButtonClassName}
          >
            <TerminalSquare className="size-3.5" />
            {isTerminalOpen ? "Hide terminal" : "Show terminal"}
          </Button>
        </div>
      </div>
      <div className="flex min-h-0 flex-1 flex-col md:flex-row">
        <div className="flex-1 min-h-0 min-w-0">
          {previewUrl ? (
            <ElectronPreviewBrowser
              persistKey={persistKey}
              src={previewUrl}
              borderRadius={6}
            />
          ) : (
            <div className="flex h-full items-center justify-center px-6 py-10">
              <div className="text-center">
                <p className="mb-2 text-sm text-neutral-500 dark:text-neutral-400">
                  {selectedRun
                    ? `Port ${port} is not available for this run`
                    : "Loading..."}
                </p>
                {availablePorts.length > 0 ? (
                  <div className="mt-4">
                    <p className="mb-2 text-xs text-neutral-400 dark:text-neutral-500">
                      Available ports:
                    </p>
                    <div className="flex flex-wrap justify-center gap-2">
                      {availablePorts.map((servicePort) => (
                        <span
                          key={servicePort}
                          className="rounded px-2 py-1 text-xs text-neutral-600 ring-1 ring-neutral-200/80 dark:text-neutral-200 dark:ring-neutral-700"
                        >
                          {servicePort}
                        </span>
                      ))}
                    </div>
                  </div>
                ) : null}
              </div>
            </div>
          )}
        </div>
        {isTerminalOpen ? (
          <div className="mt-3 flex h-[340px] shrink-0 flex-col border-t border-neutral-200/80 bg-neutral-950/80 px-3 py-3 backdrop-blur-sm dark:border-neutral-800/60 md:mt-0 md:h-full md:w-[360px] md:border-l md:border-t-0 lg:w-[420px]">
            <DevPreviewTerminal
              endpoint={devTerminalEndpoint}
              visible={isTerminalOpen}
              className="h-full"
            />
          </div>
        ) : null}
      </div>
    </div>
  );
}
