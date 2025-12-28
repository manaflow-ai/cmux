import { Dropdown } from "@/components/ui/dropdown";
import { useOpenWithActions } from "@/hooks/useOpenWithActions";
import { isElectron } from "@/lib/electron";
import clsx from "clsx";
import { EllipsisVertical, ExternalLink, GitBranch, Globe } from "lucide-react";

interface OpenWithDropdownProps {
  vscodeUrl?: string | null;
  vscodeProvider?: "docker" | "morph" | "daytona" | "bubblewrap" | "other";
  worktreePath?: string | null;
  branch?: string | null;
  networking?: Parameters<typeof useOpenWithActions>[0]["networking"];
  className?: string;
  iconClassName?: string;
}

export function OpenWithDropdown({
  vscodeUrl,
  vscodeProvider,
  worktreePath,
  branch,
  networking,
  className,
  iconClassName = "w-3.5 h-3.5",
}: OpenWithDropdownProps) {
  const {
    actions,
    executeOpenAction,
    copyBranch,
    ports,
    executePortAction,
  } = useOpenWithActions({
    vscodeUrl,
    vscodeProvider,
    worktreePath,
    branch,
    networking,
  });

  return (
    <Dropdown.Root>
      <Dropdown.Trigger
        onClick={(e) => e.stopPropagation()}
        className={clsx(
          "p-1 rounded flex items-center gap-1",
          "bg-neutral-100 dark:bg-neutral-700",
          "text-neutral-600 dark:text-neutral-400",
          "hover:bg-neutral-200 dark:hover:bg-neutral-600",
          className
        )}
        title="Open with"
      >
        <EllipsisVertical className={iconClassName} />
      </Dropdown.Trigger>
      <Dropdown.Portal>
        <Dropdown.Positioner
          sideOffset={8}
          side={isElectron ? "left" : "bottom"}
        >
          <Dropdown.Popup>
            <Dropdown.Arrow />
            <div className="px-2 py-1 text-xs font-medium text-neutral-500 dark:text-neutral-400 select-none">
              Open with
            </div>
            {actions.map((action) => {
              const Icon = action.Icon;
              return (
                <Dropdown.Item
                  key={action.id}
                  onClick={() => executeOpenAction(action)}
                  className="flex items-center gap-2"
                >
                  {Icon ? <Icon className="w-3.5 h-3.5" /> : null}
                  {action.name}
                </Dropdown.Item>
              );
            })}
            {copyBranch ? (
              <>
                <div className="my-1 h-px bg-neutral-200 dark:bg-neutral-700" />
                <Dropdown.Item
                  onClick={copyBranch}
                  className="flex items-center gap-2"
                >
                  <GitBranch className="w-3.5 h-3.5" />
                  Copy branch
                </Dropdown.Item>
              </>
            ) : null}
            {ports.length > 0 ? (
              <>
                <div className="my-1 h-px bg-neutral-200 dark:bg-neutral-700" />
                <div className="px-2 py-1 text-xs font-medium text-neutral-500 dark:text-neutral-400 select-none">
                  Forwarded ports
                </div>
                {ports.map((service) => (
                  <Dropdown.Item
                    key={service.port}
                    onClick={() => executePortAction(service)}
                    className="flex items-center justify-between w-full pr-4!"
                  >
                    <div className="flex items-center gap-2 grow">
                      <Globe className="w-3 h-3" />
                      Port {service.port}
                    </div>
                    <ExternalLink className="w-3 h-3 text-neutral-400" />
                  </Dropdown.Item>
                ))}
              </>
            ) : null}
          </Dropdown.Popup>
        </Dropdown.Positioner>
      </Dropdown.Portal>
    </Dropdown.Root>
  );
}

export default OpenWithDropdown;
