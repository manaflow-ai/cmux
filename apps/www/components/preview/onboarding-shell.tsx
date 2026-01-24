import type { ReactNode } from "react";
import clsx from "clsx";

interface OnboardingShellProps {
  sidebarHeader?: ReactNode;
  sidebarBody: ReactNode;
  sidebarFooter?: ReactNode;
  mainHeader?: ReactNode;
  mainBody: ReactNode;
  sidebarClassName?: string;
  mainClassName?: string;
}

export function OnboardingShell({
  sidebarHeader,
  sidebarBody,
  sidebarFooter,
  mainHeader,
  mainBody,
  sidebarClassName,
  mainClassName,
}: OnboardingShellProps) {
  return (
    <div className="min-h-dvh bg-white text-neutral-900 dark:bg-neutral-950 dark:text-neutral-100 flex flex-col lg:flex-row">
      <div
        className={clsx(
          "w-full lg:w-96 border-b border-neutral-200/70 dark:border-neutral-800 lg:border-b-0 lg:border-r flex flex-col bg-neutral-50/70 dark:bg-neutral-950/60",
          sidebarClassName
        )}
      >
        {sidebarHeader ? (
          <div className="p-4 border-b border-neutral-200/70 dark:border-neutral-800">
            {sidebarHeader}
          </div>
        ) : null}
        <div className="flex-1 overflow-y-auto">{sidebarBody}</div>
        {sidebarFooter ? (
          <div className="p-4 border-t border-neutral-200/70 dark:border-neutral-800 bg-white/80 dark:bg-neutral-950/80">
            {sidebarFooter}
          </div>
        ) : null}
      </div>

      <div className={clsx("flex-1 flex flex-col", mainClassName)}>
        {mainHeader ? (
          <div className="h-12 border-b border-neutral-200/70 dark:border-neutral-800 flex items-center justify-between px-4 bg-white/80 dark:bg-neutral-950/80 backdrop-blur">
            {mainHeader}
          </div>
        ) : null}
        <div className="flex-1">{mainBody}</div>
      </div>
    </div>
  );
}
