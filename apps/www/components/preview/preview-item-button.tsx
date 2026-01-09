"use client";

import { CheckCircle2, ChevronRight } from "lucide-react";
import clsx from "clsx";

export interface PreviewItemButtonProps {
  title: string;
  subtitle?: string;
  isExpanded: boolean;
  isSelected?: boolean;
  isPRMerged?: boolean;
  onToggleExpand: () => void;
  onClick: () => void;
  className?: string;
}

export function PreviewItemButton({
  title,
  subtitle,
  isExpanded,
  isSelected = false,
  isPRMerged = false,
  onToggleExpand,
  onClick,
  className,
}: PreviewItemButtonProps) {
  return (
    <div
      role="button"
      tabIndex={0}
      onClick={(e) => {
        // Only call onClick if the click wasn't on the chevron button
        if (!(e.target as HTMLElement).closest("button")) {
          onClick();
        }
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onClick();
        }
      }}
      className={clsx(
        "w-full flex items-start gap-1 px-2 py-[3px] text-[13px] text-neutral-100 hover:bg-neutral-800/45 cursor-pointer rounded-md",
        isSelected && "bg-neutral-800/30",
        className
      )}
      style={{ paddingLeft: "6px" }}
    >
      <button
        type="button"
        onClick={(e) => {
          e.preventDefault();
          e.stopPropagation();
          onToggleExpand();
        }}
        onMouseDown={(e) => e.stopPropagation()}
        className="shrink-0 grid place-content-center rounded cursor-default transition-colors size-4 self-center"
      >
        <ChevronRight
          className={clsx(
            "w-3 h-3 text-neutral-500 transition-transform pointer-events-none",
            isExpanded && "rotate-90"
          )}
        />
      </button>
      <div className="flex flex-col min-w-0 text-left flex-1 gap-0 ml-1 pointer-events-none">
        <span className="truncate font-medium">{title}</span>
        {subtitle && (
          <span className="text-[11px] text-neutral-500 truncate -mt-[1px]">
            {subtitle}
          </span>
        )}
      </div>
      <div className="pt-1 ml-auto shrink-0">
        {isPRMerged ? (
          <svg
            className="w-3 h-3 min-w-3 min-h-3 text-[#8957e5]"
            style={{ height: "12px" }}
            viewBox="0 0 16 16"
            fill="currentColor"
          >
            <path d="M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z" />
          </svg>
        ) : (
          <CheckCircle2
            className="w-3 h-3 min-w-3 min-h-3 text-green-500"
            style={{ height: "12px" }}
          />
        )}
      </div>
    </div>
  );
}
