import { useEffect, useRef } from "react";
import { toast } from "sonner";
import type { AutoUpdateEvent } from "@/types/preload";

export function AutoUpdater(): null {
  const lastProgress = useRef<number>(0);

  useEffect(() => {
    if (!("api" in window) || !window.api?.updates) return;

    const unsubscribe = window.api.updates.onUpdate((evt: AutoUpdateEvent) => {
      switch (evt.status) {
        case "checking": {
          toast.message("Checking for updates…");
          break;
        }
        case "available": {
          const ver = evt.info?.version ?? "";
          toast.info(`Update available${ver ? ` v${ver}` : ""}. Downloading…`);
          break;
        }
        case "not-available": {
          toast.message("You are on the latest version.");
          break;
        }
        case "download-progress": {
          const percent = Math.floor(evt.progress?.percent ?? 0);
          // Only update every 5%
          if (percent - lastProgress.current >= 5) {
            lastProgress.current = percent;
            toast.message(`Downloading update… ${percent}%`);
          }
          break;
        }
        case "downloaded": {
          const ver = evt.info?.version ?? "";
          toast.success(`Update ready${ver ? ` v${ver}` : ""}` , {
            action: {
              label: "Restart to update",
              onClick: () => window.api.updates.install(),
            },
          });
          break;
        }
        case "error": {
          const msg = evt.message ?? "Unknown error";
          toast.error(`Update failed: ${msg}`);
          break;
        }
      }
    });

    return () => {
      unsubscribe?.();
    };
  }, []);

  return null;
}

