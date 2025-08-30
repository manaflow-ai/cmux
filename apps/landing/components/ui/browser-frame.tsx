"use client";

import { cn } from "@/lib/utils";
import { Lock } from "lucide-react";
import type { PropsWithChildren } from "react";

type BrowserFrameProps = PropsWithChildren<{
  url: string;
  className?: string;
}>;

export function BrowserFrame({ url, className, children }: BrowserFrameProps) {
  return (
    <div
      className={cn(
        "rounded-xl border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-950 shadow-sm overflow-hidden",
        className
      )}
    >
      <div className="flex items-center gap-3 px-3 sm:px-4 h-10 border-b border-neutral-200 dark:border-neutral-800 bg-neutral-50/60 dark:bg-neutral-900/60">
        {/* Window controls */}
        <div className="flex items-center gap-1.5">
          <span className="h-3 w-3 rounded-full bg-[#ff5f56]" aria-hidden />
          <span className="h-3 w-3 rounded-full bg-[#ffbd2e]" aria-hidden />
          <span className="h-3 w-3 rounded-full bg-[#27c93f]" aria-hidden />
        </div>
        {/* Address bar */}
        <div className="flex-1 flex items-center justify-center">
          <div className="flex items-center gap-2 min-w-0 max-w-full px-3 h-7 rounded-full border border-neutral-200 dark:border-neutral-700 bg-white dark:bg-neutral-900 text-xs sm:text-sm text-neutral-700 dark:text-neutral-300 shadow-[inset_0_1px_0_rgba(255,255,255,0.5)] dark:shadow-none">
            <Lock className="h-3.5 w-3.5 text-green-600 dark:text-green-500" aria-hidden />
            <span className="truncate">{url}</span>
          </div>
        </div>
        {/* Right spacer */}
        <div className="w-6" aria-hidden />
      </div>
      <div className="bg-white dark:bg-neutral-950">{children}</div>
    </div>
  );
}

