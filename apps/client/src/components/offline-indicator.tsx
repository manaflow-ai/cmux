import { useSocket } from "@/contexts/socket/use-socket";
import { cn } from "@/lib/utils";
import { WifiOff } from "lucide-react";
import { memo, useEffect, useState, useSyncExternalStore } from "react";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";

function subscribeToBrowserOnline(callback: () => void) {
  window.addEventListener("online", callback);
  window.addEventListener("offline", callback);
  return () => {
    window.removeEventListener("online", callback);
    window.removeEventListener("offline", callback);
  };
}

function getBrowserOnlineStatus() {
  return navigator.onLine;
}

function getServerSnapshot() {
  return true;
}

function useBrowserOnline() {
  return useSyncExternalStore(
    subscribeToBrowserOnline,
    getBrowserOnlineStatus,
    getServerSnapshot
  );
}

export const OfflineIndicator = memo(function OfflineIndicator({
  className,
}: {
  className?: string;
}) {
  const isBrowserOnline = useBrowserOnline();
  const { isConnected: isSocketConnected, socket } = useSocket();

  // Add a small delay before showing the indicator to avoid flashing during brief disconnections
  const [showIndicator, setShowIndicator] = useState(false);

  const isOffline = !isBrowserOnline || (socket && !isSocketConnected);

  useEffect(() => {
    if (isOffline) {
      const timer = setTimeout(() => {
        setShowIndicator(true);
      }, 1000);
      return () => clearTimeout(timer);
    } else {
      setShowIndicator(false);
    }
  }, [isOffline]);

  if (!showIndicator) {
    return null;
  }

  const message = !isBrowserOnline
    ? "You're offline. Check your internet connection."
    : "Connection lost. Reconnecting...";

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <div
          className={cn(
            "flex items-center gap-1.5 px-2 py-1 rounded-md",
            "bg-amber-100 dark:bg-amber-900/30",
            "text-amber-700 dark:text-amber-400",
            "text-xs font-medium",
            "animate-in fade-in duration-200",
            className
          )}
        >
          <WifiOff className="h-3.5 w-3.5" />
          <span>Offline</span>
        </div>
      </TooltipTrigger>
      <TooltipContent side="bottom">
        <p>{message}</p>
      </TooltipContent>
    </Tooltip>
  );
});
