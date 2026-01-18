import { env } from "@/client-env";
import { Dropdown } from "@/components/ui/dropdown";
import { Link } from "@tanstack/react-router";
import clsx from "clsx";
import { Cloud, Monitor, Plus } from "lucide-react";
import { useCallback } from "react";

interface SidebarWorkspacesSectionProps {
  teamSlugOrId: string;
}

function openCommandBarWithPage(page: string) {
  window.dispatchEvent(
    new CustomEvent("cmux:open-command-bar", { detail: { page } })
  );
}

export function SidebarWorkspacesSection({
  teamSlugOrId,
}: SidebarWorkspacesSectionProps) {
  const handleLocalWorkspace = useCallback(() => {
    openCommandBarWithPage("local-workspaces");
  }, []);

  const handleCloudWorkspace = useCallback(() => {
    openCommandBarWithPage("cloud-workspaces");
  }, []);

  return (
    <div className="flex items-center justify-between ml-2" data-onboarding="workspaces-link">
      <Link
        to="/$teamSlugOrId/workspaces"
        params={{ teamSlugOrId }}
        activeOptions={{ exact: true }}
        className={clsx(
          "pointer-default cursor-default flex items-center rounded-sm pl-2 pr-3 py-0.5 text-[12px] font-medium text-neutral-600 select-none hover:bg-neutral-200/45 dark:text-neutral-300 dark:hover:bg-neutral-800/45 data-[active=true]:hover:bg-neutral-200/75 dark:data-[active=true]:hover:bg-neutral-800/65"
        )}
        activeProps={{
          className:
            "bg-neutral-200/75 text-neutral-900 dark:bg-neutral-800/65 dark:text-neutral-100",
          "data-active": "true",
        }}
      >
        Workspaces
      </Link>
      <Dropdown.Root>
        <Dropdown.Trigger
          className={clsx(
            "p-1 mr-[3px] flex items-center justify-center",
            "text-neutral-500 dark:text-neutral-400",
            "hover:text-neutral-700 dark:hover:text-neutral-200",
            "transition-colors"
          )}
          title="New workspace"
        >
          <Plus className="w-3.5 h-3.5" aria-hidden="true" />
        </Dropdown.Trigger>
        <Dropdown.Portal>
          <Dropdown.Positioner sideOffset={4} side="bottom" align="end">
            <Dropdown.Popup className="min-w-[180px]">
              {!env.NEXT_PUBLIC_WEB_MODE && (
                <Dropdown.Item
                  onClick={handleLocalWorkspace}
                  className="flex items-center gap-2"
                >
                  <Monitor className="w-3.5 h-3.5 text-neutral-500 dark:text-neutral-400" />
                  <span>Local Workspace</span>
                </Dropdown.Item>
              )}
              <Dropdown.Item
                onClick={handleCloudWorkspace}
                className="flex items-center gap-2"
              >
                <Cloud className="w-4 h-4 text-neutral-500 dark:text-neutral-400" />
                <span>Cloud Workspace</span>
              </Dropdown.Item>
            </Dropdown.Popup>
          </Dropdown.Positioner>
        </Dropdown.Portal>
      </Dropdown.Root>
    </div>
  );
}
