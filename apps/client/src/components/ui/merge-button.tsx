import { cn } from "@/lib/utils";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { Check, ChevronDown, GitMerge, GitPullRequest, Loader2 } from "lucide-react";
import { useState } from "react";

export type MergeMethod = "squash" | "rebase" | "merge";

interface MergeButtonProps {
  onMerge: (method: MergeMethod) => void;
  isOpen?: boolean;
  className?: string;
  disabled?: boolean;
  isMerged?: boolean;
  isMerging?: boolean;
  isCreatingPr?: boolean;
}

const mergeOptions = [
  {
    value: "squash" as const,
    label: "Squash and merge",
    description: "All commits will be squashed into one",
    icon: GitMerge,
  },
  {
    value: "rebase" as const,
    label: "Rebase and merge",
    description: "All commits will be rebased",
    icon: GitMerge,
  },
  {
    value: "merge" as const,
    label: "Create a merge commit",
    description: "All commits will be merged with a merge commit",
    icon: GitMerge,
  },
];

export function MergeButton({
  onMerge,
  isOpen = false,
  className,
  disabled = false,
  isMerged = false,
  isMerging = false,
  isCreatingPr = false,
}: MergeButtonProps) {
  const [selectedMethod, setSelectedMethod] = useState<MergeMethod>("squash");
  const [dropdownOpen, setDropdownOpen] = useState(false);

  const selectedOption = mergeOptions.find(
    (opt) => opt.value === selectedMethod
  );

  const handleMerge = () => {
    if (!isMerged && !isMerging) {
      onMerge(selectedMethod);
    }
  };

  // Show merged state with GitHub's purple color
  if (isMerged) {
    return (
      <button
        disabled
        className={cn(
          "flex items-center gap-1.5 px-3 py-1 bg-[#8250df] dark:bg-[#6639ba] text-white rounded cursor-not-allowed font-medium text-xs select-none whitespace-nowrap",
          className
        )}
      >
        <Check className="w-3.5 h-3.5" />
        Merged
      </button>
    );
  }

  // Show creating PR state
  if (isCreatingPr) {
    return (
      <button
        disabled
        className={cn(
          "flex items-center gap-1.5 px-3 py-1 bg-neutral-500 text-white rounded cursor-not-allowed font-medium text-xs select-none whitespace-nowrap",
          className
        )}
      >
        <Loader2 className="w-3.5 h-3.5 animate-spin" />
        Opening PR...
      </button>
    );
  }

  // Show merging state with GitHub's green color
  if (isMerging) {
    return (
      <button
        disabled
        className={cn(
          "flex items-center gap-1.5 px-3 py-1 bg-[#1f883d] dark:bg-[#238636] text-white rounded cursor-not-allowed font-medium text-xs select-none whitespace-nowrap",
          className
        )}
      >
        <Loader2 className="w-3.5 h-3.5 animate-spin" />
        Merging...
      </button>
    );
  }

  if (!isOpen) {
    return (
      <button
        onClick={() => onMerge("squash")}
        disabled={disabled}
        className={cn(
          "flex items-center gap-1.5 px-3 py-1 bg-[#1f883d] dark:bg-[#238636] text-white rounded hover:bg-[#1f883d]/90 dark:hover:bg-[#238636]/90 disabled:opacity-50 disabled:cursor-not-allowed font-medium text-xs select-none whitespace-nowrap",
          className
        )}
      >
        <GitPullRequest className="w-3.5 h-3.5" />
        Open PR
      </button>
    );
  }

  return (
    <div className="flex items-stretch">
      <button
        onClick={handleMerge}
        disabled={disabled}
        className={cn(
          "flex items-center gap-1.5 px-3 py-1 bg-[#1f883d] dark:bg-[#238636] text-white rounded-l hover:bg-[#1f883d]/90 dark:hover:bg-[#238636]/90 disabled:opacity-50 disabled:cursor-not-allowed font-medium text-xs border-r border-green-700 select-none whitespace-nowrap",
          className
        )}
      >
        <GitMerge className="w-3.5 h-3.5" />
        {selectedOption?.label}
      </button>

      <DropdownMenu.Root open={dropdownOpen} onOpenChange={setDropdownOpen}>
        <DropdownMenu.Trigger asChild>
          <button
            disabled={disabled}
            className="flex items-center px-2 py-1 bg-[#1f883d] dark:bg-[#238636] text-white rounded-r hover:bg-[#1f883d]/90 dark:hover:bg-[#238636]/90 disabled:opacity-50 disabled:cursor-not-allowed select-none"
          >
            <ChevronDown className="w-3.5 h-3.5" />
          </button>
        </DropdownMenu.Trigger>

        <DropdownMenu.Portal>
          <DropdownMenu.Content
            className="min-w-[220px] bg-white dark:bg-neutral-900 rounded-md p-1 shadow-lg border border-neutral-200 dark:border-neutral-800 z-50"
            sideOffset={5}
          >
            {mergeOptions.map((option) => (
              <DropdownMenu.Item
                key={option.value}
                onClick={() => setSelectedMethod(option.value)}
                className={cn(
                  "flex flex-col items-start px-2 py-1.5 mb-[1px] text-xs rounded cursor-default outline-none select-none",
                  "hover:bg-neutral-100 dark:hover:bg-neutral-800",
                  "focus-visible:bg-neutral-100 dark:focus-visible:bg-neutral-800 focus-visible:ring-2 focus-visible:ring-black dark:focus-visible:ring-white focus-visible:ring-offset-1",
                  selectedMethod === option.value &&
                    "bg-neutral-100 dark:bg-neutral-800"
                )}
              >
                <div className="flex items-center gap-2 font-medium">
                  <option.icon className="w-3.5 h-3.5" />
                  {option.label}
                </div>
                <div className="text-[10px] text-neutral-500 dark:text-neutral-400 ml-5">
                  {option.description}
                </div>
              </DropdownMenu.Item>
            ))}
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
    </div>
  );
}
