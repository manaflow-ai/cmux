import { env } from "@/client-env";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useSocket } from "@/contexts/socket/use-socket";
import type { ProviderStatus, ProviderStatusResponse } from "@cmux/shared";
import { useNavigate } from "@tanstack/react-router";
import clsx from "clsx";
import { RefreshCw } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

export function ProviderStatusPills({ teamSlugOrId }: { teamSlugOrId: string }) {
  const { socket } = useSocket();
  const navigate = useNavigate();
  const [status, setStatus] = useState<ProviderStatusResponse | null>(null);
  const [isVisible, setIsVisible] = useState(false);

  const checkProviderStatus = useCallback(() => {
    if (!socket) return;

    socket.emit("check-provider-status", (response) => {
      if (response.success) {
        setStatus(response);
        // Delay visibility to create fade-in effect
        setTimeout(() => setIsVisible(true), 100);
      }
    });
  }, [socket]);

  // Check status on mount and every 5 seconds so UI updates quickly
  useEffect(() => {
    checkProviderStatus();
    const interval = setInterval(checkProviderStatus, 5000);
    return () => clearInterval(interval);
  }, [checkProviderStatus]);

  if (!status) return null;

  // Get providers that are not available
  const unavailableProviders =
    status.providers?.filter((p: ProviderStatus) => !p.isAvailable) ?? [];

  // In web mode, Docker status is not relevant
  const dockerNotReady =
    !env.NEXT_PUBLIC_WEB_MODE && !status.dockerStatus?.isRunning;
  const dockerImageNotReady =
    !env.NEXT_PUBLIC_WEB_MODE &&
    status.dockerStatus?.workerImage &&
    !status.dockerStatus.workerImage.isAvailable;
  const dockerImagePulling =
    !env.NEXT_PUBLIC_WEB_MODE && status.dockerStatus?.workerImage?.isPulling;

  // Count total available and unavailable providers
  const totalProviders = status.providers?.length ?? 0;
  const availableProviders = totalProviders - unavailableProviders.length;

  // If everything is ready, don't show anything
  if (
    unavailableProviders.length === 0 &&
    !dockerNotReady &&
    !dockerImageNotReady
  ) {
    return null;
  }

  return (
    <div
      className={clsx(
        "absolute left-0 right-0 -top-9 flex justify-center pointer-events-none z-[var(--z-low)]",
        "transition-all duration-500 ease-out",
        isVisible ? "opacity-100 translate-y-0" : "opacity-0 -translate-y-2"
      )}
    >
      <div
        className="pointer-events-auto overflow-y-auto overflow-x-hidden px-1.5 py-1"
        style={{ maxHeight: "min(20rem, calc(100vh - 6rem))" }}
      >
        <div
          className="mx-auto grid w-full max-w-2xl gap-1"
          style={{
            gridTemplateColumns: "repeat(auto-fit, minmax(6.25rem, 1fr))",
            gridAutoFlow: "row dense",
          }}
        >
          {/* Summary pill when there are issues */}
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                onClick={() =>
                  navigate({
                    to: "/$teamSlugOrId/settings",
                    params: { teamSlugOrId },
                  })
                }
                className={clsx(
                  "flex w-full flex-col items-start gap-0.5 rounded-md px-1.5 py-1",
                  "bg-neutral-100 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-600",
                  "text-neutral-800 dark:text-neutral-200",
                  "text-[10px] font-medium cursor-default select-none leading-tight",
                  "min-w-0"
                )}
              >
                <div className="flex items-center gap-1">
                  <div className="h-1.5 w-1.5 rounded-full bg-red-500"></div>
                  <span className="truncate font-semibold">Setup</span>
                </div>
                <div className="flex items-center gap-1 text-[9px] text-neutral-600 dark:text-neutral-300">
                  {availableProviders > 0 && (
                    <span className="text-emerald-600 dark:text-emerald-400 font-medium">
                      {availableProviders} ready
                    </span>
                  )}
                  {unavailableProviders.length > 0 && (
                    <span className="text-amber-600 dark:text-amber-400 font-medium">
                      {unavailableProviders.length} pending
                    </span>
                  )}
                </div>
              </button>
            </TooltipTrigger>
            <TooltipContent className="max-w-xs">
              <p className="font-medium mb-1">Configuration Needed</p>
              <div className="text-xs space-y-1">
                {dockerNotReady && <p>• Docker needs to be running</p>}
                {dockerImageNotReady && !dockerImagePulling && (
                  <p>
                    • Docker image {status.dockerStatus?.workerImage?.name} not
                    available
                  </p>
                )}
                {dockerImagePulling && (
                  <p>
                    • Docker image {status.dockerStatus?.workerImage?.name} is
                    pulling...
                  </p>
                )}
                <p className="text-slate-500 dark:text-slate-400 mt-2 pt-1 border-t border-slate-200 dark:border-slate-700">
                  Click to open settings
                </p>
              </div>
            </TooltipContent>
          </Tooltip>

          {dockerNotReady && (
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  onClick={() => {
                    window.open("https://www.docker.com/products/docker-desktop/", "_blank");
                  }}
                  className={clsx(
                    "flex w-full items-center gap-1 rounded-md px-1.5 py-1",
                    "bg-neutral-100 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-600",
                    "text-neutral-800 dark:text-neutral-200",
                    "text-[10px] font-medium cursor-default select-none leading-tight",
                    "min-w-0"
                  )}
                >
                  <div className="h-1.5 w-1.5 rounded-full bg-orange-500"></div>
                  <span className="truncate font-medium">Docker</span>
                </button>
              </TooltipTrigger>
              <TooltipContent>
                <p className="font-medium">Docker Required</p>
                <p className="text-xs opacity-90">
                  Start Docker to enable containerized development environments
                </p>
              </TooltipContent>
            </Tooltip>
          )}
          {dockerImageNotReady && (
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  onClick={() =>
                    navigate({
                      to: "/$teamSlugOrId/settings",
                      params: { teamSlugOrId },
                    })
                  }
                  className={clsx(
                    "flex w-full items-center gap-1 rounded-md px-1.5 py-1",
                    "bg-neutral-100 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-600",
                    "text-neutral-800 dark:text-neutral-200",
                    "text-[10px] font-medium cursor-default select-none leading-tight",
                    "min-w-0"
                  )}
                >
                  {dockerImagePulling ? (
                    <RefreshCw className="h-3 w-3 text-blue-500 animate-spin" />
                  ) : (
                    <div className="h-1.5 w-1.5 rounded-full bg-yellow-500"></div>
                  )}
                  <span className="truncate font-medium">Image</span>
                </button>
              </TooltipTrigger>
              <TooltipContent>
                <p className="font-medium">Docker Image</p>
                <p className="text-xs opacity-90">
                  {dockerImagePulling
                    ? `Pulling ${status.dockerStatus?.workerImage?.name}...`
                    : `${status.dockerStatus?.workerImage?.name} needs to be downloaded`}
                </p>
              </TooltipContent>
            </Tooltip>
          )}
        </div>
      </div>
    </div>
  );
}
