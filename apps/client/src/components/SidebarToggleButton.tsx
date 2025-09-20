import clsx from "clsx";
import { ChevronRight } from "lucide-react";
import type { CSSProperties, MouseEvent } from "react";

interface SidebarToggleButtonProps {
  isExpanded: boolean;
  onClick: (event: MouseEvent<HTMLButtonElement>) => void;
  isVisible?: boolean;
  className?: string;
  iconClassName?: string;
}

export function SidebarToggleButton({
  isExpanded,
  onClick,
  isVisible = true,
  className,
  iconClassName,
}: SidebarToggleButtonProps) {
  return (
    <button
      onClick={onClick}
      className={clsx(
        "grid place-content-center rounded cursor-default transition-colors",
        !isVisible && "invisible",
        className
      )}
      style={{ WebkitAppRegion: "no-drag" } as CSSProperties}
    >
      <ChevronRight
        className={clsx(
          "transition-transform w-3 h-3",
          isExpanded && "rotate-90",
          iconClassName
        )}
      />
    </button>
  );
}
