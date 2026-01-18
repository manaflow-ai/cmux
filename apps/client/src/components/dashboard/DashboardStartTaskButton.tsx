import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { Command } from "lucide-react";

interface DashboardStartTaskButtonProps {
  canSubmit: boolean;
  onStartTask: () => void;
  disabledReason?: string;
  isStarting: boolean;
}

export function DashboardStartTaskButton({
  canSubmit,
  onStartTask,
  disabledReason,
  isStarting,
}: DashboardStartTaskButtonProps) {
  const isMac = navigator.userAgent.toUpperCase().indexOf("MAC") >= 0;
  const isDisabled = isStarting || !canSubmit || !!disabledReason;

  return (
    <Tooltip delayDuration={0}>
      {/* Wrap disabled button in a span so tooltip still shows */}
      <TooltipTrigger asChild>
        <span
          // Ensure tooltip can trigger even when the button is disabled
          tabIndex={0}
          className="inline-flex"
          data-onboarding="start-button"
        >
          <Button
            size="sm"
            variant="default"
            className="!h-7 focus-visible:ring-offset-1 focus-visible:ring-offset-white dark:focus-visible:ring-offset-neutral-900"
            onClick={onStartTask}
            disabled={isDisabled}
            aria-busy={isStarting}
          >
            {isStarting ? "Starting..." : "Start task"}
          </Button>
        </span>
      </TooltipTrigger>
      <TooltipContent
        side="bottom"
        className="flex items-center gap-1 bg-black text-white border-black [&>*:last-child]:bg-black [&>*:last-child]:fill-black"
      >
        {disabledReason ? (
          <span className="text-xs">{disabledReason}</span>
        ) : (
          <>
            {isMac ? (
              <Command className="w-3 h-3" />
            ) : (
              <span className="text-xs">Ctrl</span>
            )}
            <span>+ Enter</span>
          </>
        )}
      </TooltipContent>
    </Tooltip>
  );
}
