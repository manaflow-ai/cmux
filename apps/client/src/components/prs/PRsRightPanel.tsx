import { Outlet } from "@tanstack/react-router";

export function PRsRightPanel({ selectedKey }: { selectedKey: string | null }) {
  return (
    <div className="min-w-0 min-h-0 h-full bg-white dark:bg-black flex flex-col overflow-y-auto">
      {selectedKey ? (
        <Outlet />
      ) : (
        <div className="flex-1 w-full flex items-center justify-center text-neutral-500 dark:text-neutral-400">
          Select a pull request
        </div>
      )}
    </div>
  );
}

export default PRsRightPanel;

