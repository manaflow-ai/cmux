import { cn } from "@/lib/utils";

export interface SidebarResizeHandleProps {
  isResizing: boolean;
  onPointerDown: (event: React.PointerEvent<HTMLDivElement>) => void;
  onKeyDown: (event: React.KeyboardEvent<HTMLDivElement>) => void;
  onDoubleClick: () => void;
  sidebarPanelId: string;
  currentWidth: number;
  minWidth: number;
  maxWidth: number;
  className?: string;
}

export function SidebarResizeHandle({
  isResizing,
  onPointerDown,
  onKeyDown,
  onDoubleClick,
  sidebarPanelId,
  currentWidth,
  minWidth,
  maxWidth,
  className,
}: SidebarResizeHandleProps) {
  return (
    <div
      className={cn(
        "absolute top-0 bottom-0 right-0 w-2 cursor-col-resize select-none touch-none group/resize z-10 translate-x-1/2",
        "focus-visible:outline-2 focus-visible:outline-offset-0 focus-visible:outline-sky-500",
        className
      )}
      role="separator"
      aria-label="Resize file navigation panel"
      aria-orientation="vertical"
      aria-controls={sidebarPanelId}
      aria-valuenow={Math.round(currentWidth)}
      aria-valuemin={minWidth}
      aria-valuemax={maxWidth}
      tabIndex={0}
      onPointerDown={onPointerDown}
      onKeyDown={onKeyDown}
      onDoubleClick={onDoubleClick}
    >
      <span className="sr-only">Drag to adjust file navigation width</span>
      <div
        className={cn(
          "absolute top-0 bottom-0 left-1/2 -translate-x-1/2 w-[3px] rounded-full transition-opacity",
          isResizing
            ? "bg-sky-500 dark:bg-sky-400 opacity-100"
            : "opacity-0 group-hover/resize:opacity-100 group-hover/resize:bg-sky-500 dark:group-hover/resize:bg-sky-400"
        )}
        aria-hidden
      />
    </div>
  );
}
