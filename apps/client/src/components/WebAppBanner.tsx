import { isElectron } from "@/lib/electron";
import { X } from "lucide-react";
import { useState, useEffect } from "react";

const BANNER_DISMISSED_KEY = "cmux-web-banner-dismissed";

export function WebAppBanner() {
  const [isDismissed, setIsDismissed] = useState(() => {
    if (typeof window === "undefined") return true;
    return localStorage.getItem(BANNER_DISMISSED_KEY) === "true";
  });

  useEffect(() => {
    if (isDismissed) {
      localStorage.setItem(BANNER_DISMISSED_KEY, "true");
    }
  }, [isDismissed]);

  // Don't show in Electron app
  if (isElectron) return null;

  // Don't show if dismissed
  if (isDismissed) return null;

  return (
    <div className="bg-[#1e3a5f] text-white/90 text-xs py-1 px-3 flex items-center justify-center gap-2 shrink-0">
      <span className="text-center">
        cmux is open source.{" "}
        <a
          href="https://cmux.dev"
          target="_blank"
          rel="noopener noreferrer"
          className="underline hover:text-white"
        >
          Download the desktop app
        </a>{" "}
        for the best experience.
      </span>
      <button
        onClick={() => setIsDismissed(true)}
        className="ml-1 p-0.5 hover:bg-white/10 rounded transition-colors"
        aria-label="Dismiss banner"
      >
        <X className="w-3 h-3" />
      </button>
    </div>
  );
}
