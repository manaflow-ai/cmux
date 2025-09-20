import { Command } from "cmdk";
import { ClipboardCopy, ScrollText } from "lucide-react";

interface ElectronLogsCommandItemsProps {
  onSelect: (value: string) => void;
}

export function ElectronLogsCommandItems({
  onSelect,
}: ElectronLogsCommandItemsProps) {
  const itemClassName =
    "flex items-center gap-2 px-3 py-2.5 mx-1 rounded-md cursor-pointer hover:bg-neutral-100 dark:hover:bg-neutral-800 data-[selected=true]:bg-neutral-100 dark:data-[selected=true]:bg-neutral-800 data-[selected=true]:text-neutral-900 dark:data-[selected=true]:text-neutral-100";

  return (
    <Command.Group>
      <div className="px-2 py-1.5 text-xs text-neutral-500 dark:text-neutral-400">
        Logs
      </div>
      <Command.Item
        value="logs:view"
        onSelect={() => onSelect("logs:view")}
        className={itemClassName}
      >
        <ScrollText className="h-4 w-4 text-blue-500" />
        <span className="text-sm">Logs: View</span>
      </Command.Item>
      <Command.Item
        value="logs:copy"
        onSelect={() => onSelect("logs:copy")}
        className={itemClassName}
      >
        <ClipboardCopy className="h-4 w-4 text-violet-500" />
        <span className="text-sm">Logs: Copy all</span>
      </Command.Item>
    </Command.Group>
  );
}
