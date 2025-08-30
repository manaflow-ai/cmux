import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip";
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

  // Check status on mount and every 30 seconds
  useEffect(() => {
    checkProviderStatus();
    const interval = setInterval(checkProviderStatus, 30000);
    return () => clearInterval(interval);
  }, [checkProviderStatus]);

  if (!status) return null;

  // Get providers that are not available
  const unavailableProviders =
    status.providers?.filter((p: ProviderStatus) => !p.isAvailable) ?? [];

  const dockerNotReady = !status.dockerStatus?.isRunning;
  const gitNotReady = !status.gitStatus?.isAvailable;
  const dockerImageNotReady =
    status.dockerStatus?.workerImage &&
    !status.dockerStatus.workerImage.isAvailable;
  const dockerImagePulling = status.dockerStatus?.workerImage?.isPulling;
  const githubNotConfigured = !status.githubStatus?.hasToken;

  // Count total available and unavailable providers
  const totalProviders = status.providers?.length ?? 0;
  const availableProviders = totalProviders - unavailableProviders.length;

  // If everything is ready, don't show anything
  if (
    unavailableProviders.length === 0 &&
    !dockerNotReady &&
    !gitNotReady &&
    !dockerImageNotReady &&
    !githubNotConfigured
  ) {
    return null;
  }

  return (
    <div
      className={clsx(
        "absolute left-0 right-0 -top-9 flex justify-center pointer-events-none z-10",
        "transition-all duration-500 ease-out",
        isVisible ? "opacity-100 translate-y-0" : "opacity-0 -translate-y-2"
      )}
    >
      <TooltipProvider>
        <div className="flex items-center gap-2 pointer-events-auto">
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
                  "flex items-center gap-2 px-3 py-1.5 rounded-lg",
                  "bg-neutral-100 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-600",
                  "text-neutral-800 dark:text-neutral-200",
                  "text-xs font-medium cursor-default select-none"
                )}
              >
                <div className="w-2 h-2 rounded-full bg-red-500"></div>
                <span>Setup required</span>
                <div className="flex items-center gap-1">
                  {availableProviders > 0 && (
                    <span className="text-emerald-600 dark:text-emerald-400 text-[10px] font-normal">
                      {availableProviders} ready
                    </span>
                  )}
                  {unavailableProviders.length > 0 && (
                    <span className="text-amber-600 dark:text-amber-400 text-[10px] font-normal">
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
                {gitNotReady && <p>• Git installation required</p>}
                {githubNotConfigured && (
                  <p>• GitHub PAT token configuration needed</p>
                )}
                {unavailableProviders.length > 0 && (
                  <p>
                    • {unavailableProviders.length} AI provider
                    {unavailableProviders.length > 1 ? "s" : ""} need setup
                  </p>
                )}
                <p className="text-slate-500 dark:text-slate-400 mt-2 pt-1 border-t border-slate-200 dark:border-slate-700">
                  Click to open settings
                </p>
              </div>
            </TooltipContent>
          </Tooltip>

          {/* Individual issue pills - only show critical ones */}
          {dockerNotReady && (
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
                    "flex items-center gap-1.5 px-2.5 py-1 rounded-lg",
                    "bg-neutral-100 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-600",
                    "text-neutral-800 dark:text-neutral-200",
                    "text-xs font-medium cursor-default select-none"
                  )}
                >
                  <div className="w-1.5 h-1.5 rounded-full bg-orange-500"></div>
                  Docker
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

          {gitNotReady && (
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
                    "flex items-center gap-1.5 px-2.5 py-1 rounded-lg",
                    "bg-neutral-100 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-600",
                    "text-neutral-800 dark:text-neutral-200",
                    "text-xs font-medium cursor-default select-none"
                  )}
                >
                  <div className="w-1.5 h-1.5 rounded-full bg-red-500"></div>
                  Git
                </button>
              </TooltipTrigger>
              <TooltipContent>
                <p className="font-medium">Git Installation</p>
                <p className="text-xs opacity-90">
                  Git is required for repository management and version control
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
                    "flex items-center gap-1.5 px-2.5 py-1 rounded-lg",
                    "bg-neutral-100 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-600",
                    "text-neutral-800 dark:text-neutral-200",
                    "text-xs font-medium cursor-default select-none"
                  )}
                >
                  {dockerImagePulling ? (
                    <RefreshCw className="w-3 h-3 text-blue-500 animate-spin" />
                  ) : (
                    <div className="w-1.5 h-1.5 rounded-full bg-yellow-500"></div>
                  )}
                  Image
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

          {githubNotConfigured && (
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
                    "flex items-center gap-1.5 px-2.5 py-1 rounded-lg",
                    "bg-neutral-100 dark:bg-neutral-800 border border-neutral-200 dark:border-neutral-600",
                    "text-neutral-800 dark:text-neutral-200",
                    "text-xs font-medium cursor-default select-none"
                  )}
                >
                  <div className="w-1.5 h-1.5 rounded-full bg-amber-500"></div>
                  Add GitHub token
                </button>
              </TooltipTrigger>
              <TooltipContent>
                <p className="font-medium">
                  Optional: Configure GitHub Personal Access Token
                </p>
                <p className="text-xs opacity-90">
                  Configure your GitHub Personal Access Token to enable
                  automatic PR creation and repository management
                </p>
              </TooltipContent>
            </Tooltip>
          )}
        </div>
      </TooltipProvider>
    </div>
  );
}
