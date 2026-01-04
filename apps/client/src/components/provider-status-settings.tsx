import { env } from "@/client-env";
import { useSocket } from "@/contexts/socket/use-socket";
import type { ProviderStatus, ProviderStatusResponse } from "@cmux/shared";
import { AlertCircle, CheckCircle2, RefreshCw, XCircle } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

export function ProviderStatusSettings() {
  const { socket } = useSocket();
  const [status, setStatus] = useState<ProviderStatusResponse | null>(null);
  const [loading, setLoading] = useState(true);

  const checkProviderStatus = useCallback(() => {
    if (!socket) return;

    setLoading(true);
    socket.emit("check-provider-status", (response) => {
      setLoading(false);
      if (response.success) {
        setStatus(response);
      } else {
        console.error("Failed to check provider status:", response.error);
      }
    });
  }, [socket]);

  // Check status on mount and every 5 seconds
  useEffect(() => {
    checkProviderStatus();
    const interval = setInterval(checkProviderStatus, 5000);
    return () => clearInterval(interval);
  }, [checkProviderStatus]);

  // Skeleton loader
  if (loading && !status) {
    return (
      <div className="space-y-3 animate-pulse">
        {/* Refresh button skeleton */}
        <div className="flex justify-end -mt-1 -mb-2">
          <div className="h-4 w-16 bg-neutral-200 dark:bg-neutral-700 rounded" />
        </div>

        {/* Combined Status Grid skeleton */}
        <div className="grid grid-cols-2 gap-x-6 gap-y-1.5">
          {/* Docker skeleton */}
          {!env.NEXT_PUBLIC_WEB_MODE && (
            <div className="flex items-center gap-2">
              <div className="w-3.5 h-3.5 rounded-full bg-neutral-300 dark:bg-neutral-600" />
              <div className="w-20 leading-3 bg-neutral-200 text-transparent dark:bg-neutral-700 rounded text-xs">
                loading...
              </div>
            </div>
          )}

          {/* Git skeleton - hidden in web mode */}
          {!env.NEXT_PUBLIC_WEB_MODE && (
            <div className="flex items-center gap-2">
              <div className="w-3.5 h-3.5 rounded-full bg-neutral-300 dark:bg-neutral-600" />
              <div className="w-20 leading-3 bg-neutral-200 text-transparent dark:bg-neutral-700 rounded text-xs">
                loading...
              </div>
            </div>
          )}

          {/* AI Provider skeletons - typically 10 providers */}
          {[...Array(8)].map((_, i) => (
            <div key={i} className="flex items-center gap-2">
              <div className="w-3.5 h-3.5 rounded-full bg-neutral-300 dark:bg-neutral-600" />
              <div className="w-20 leading-3 bg-neutral-200 text-transparent dark:bg-neutral-700 rounded text-xs">
                loading...
              </div>
            </div>
          ))}
        </div>
      </div>
    );
  }

  if (!status) return null;

  const dockerOk = status.dockerStatus?.isRunning ?? false;
  const gitOk = status.gitStatus?.isAvailable ?? false;
  const dockerImage = status.dockerStatus?.workerImage;

  return (
    <div className="space-y-3">
      {/* Refresh button */}
      <div className="flex justify-end -mt-1 -mb-2">
        <button
          onClick={checkProviderStatus}
          className="text-xs text-blue-600 dark:text-blue-400 hover:underline flex items-center gap-1"
          disabled={loading}
        >
          {loading ? (
            <RefreshCw className="w-3 h-3 animate-spin" />
          ) : (
            <RefreshCw className="w-3 h-3" />
          )}
          Refresh
        </button>
      </div>

      {/* Combined Status Grid */}
      <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-xs">
        {/* Docker Status - hidden in web mode */}
        {!env.NEXT_PUBLIC_WEB_MODE && (
          <div className="flex items-center gap-2">
            {dockerOk ? (
              <CheckCircle2 className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
            ) : (
              <XCircle className="w-3.5 h-3.5 text-red-500 flex-shrink-0" />
            )}
            <span className="text-xs text-neutral-700 dark:text-neutral-300 select-text">
              Docker required
              {dockerOk &&
                status.dockerStatus?.version &&
                ` ${status.dockerStatus.version}`}
            </span>
          </div>
        )}

        {/* Docker Image Status - hidden in web mode */}
        {!env.NEXT_PUBLIC_WEB_MODE && dockerImage && (
          <div className="flex items-center gap-2">
            {dockerImage.isAvailable ? (
              <CheckCircle2 className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
            ) : dockerImage.isPulling ? (
              <RefreshCw className="w-3.5 h-3.5 text-blue-500 flex-shrink-0 animate-spin" />
            ) : (
              <AlertCircle className="w-3.5 h-3.5 text-yellow-500 flex-shrink-0" />
            )}
            <span className="text-xs text-neutral-700 dark:text-neutral-300 select-text">
              {dockerImage.name}
              {dockerImage.isPulling && " (pulling...)"}
              {!dockerImage.isAvailable &&
                !dockerImage.isPulling &&
                " (not available)"}
            </span>
          </div>
        )}

        {/* Git Status - hidden in web mode */}
        {!env.NEXT_PUBLIC_WEB_MODE && (
          <div className="flex items-center gap-2">
            {gitOk ? (
              <CheckCircle2 className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
            ) : (
              <XCircle className="w-3.5 h-3.5 text-red-500 flex-shrink-0" />
            )}
            <span className="text-xs text-neutral-700 dark:text-neutral-300 select-text">
              Git
              {gitOk &&
                status.gitStatus?.version &&
                ` ${status.gitStatus.version}`}
            </span>
          </div>
        )}

        {/* AI Providers */}
        {status.providers?.map((provider: ProviderStatus) => {
          return (
            <div key={provider.name} className="flex items-center gap-2">
              {provider.isAvailable ? (
                <CheckCircle2 className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
              ) : (
                <AlertCircle className="w-3.5 h-3.5 text-yellow-500 flex-shrink-0" />
              )}
              <div className="min-w-0 flex flex-col">
                <div className="flex items-center gap-1">
                  <span className="text-xs text-neutral-700 dark:text-neutral-300 select-text">
                    {provider.name}
                  </span>
                </div>
                {!provider.isAvailable &&
                  provider.missingRequirements &&
                  provider.missingRequirements.length > 0 && (
                    <div className="text-xs text-neutral-500 dark:text-neutral-400 truncate">
                      {provider.missingRequirements[0]}
                    </div>
                  )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
