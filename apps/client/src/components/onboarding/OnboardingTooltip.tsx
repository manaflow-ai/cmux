import { useCallback, useEffect, useState, type CSSProperties } from "react";
import type { OnboardingStep } from "@/contexts/onboarding";
import { ChevronLeft, ChevronRight, X } from "lucide-react";

interface TooltipPosition {
  top: number;
  left: number;
  arrowPosition?: "top" | "bottom" | "left" | "right";
}

interface OnboardingTooltipProps {
  step: OnboardingStep;
  currentIndex: number;
  totalSteps: number;
  onNext: () => void;
  onPrevious: () => void;
  onSkip: () => void;
  isLastStep: boolean;
  isFirstStep: boolean;
}

const TOOLTIP_WIDTH = 280;
const TOOLTIP_HEIGHT = 160; // Approximate height for collision detection
const TOOLTIP_OFFSET = 12;
const ARROW_SIZE = 6;

export function OnboardingTooltip({
  step,
  currentIndex,
  totalSteps,
  onNext,
  onPrevious,
  onSkip,
  isLastStep,
  isFirstStep,
}: OnboardingTooltipProps) {
  const [position, setPosition] = useState<TooltipPosition>({ top: 0, left: 0 });

  const calculatePosition = useCallback(() => {
    // Center placement - show in the middle of the screen
    if (step.placement === "center" || !step.targetSelector) {
      const viewportWidth = window.innerWidth;
      const viewportHeight = window.innerHeight;
      setPosition({
        top: viewportHeight / 2 - 100,
        left: viewportWidth / 2 - TOOLTIP_WIDTH / 2,
      });
      return;
    }

    const element = document.querySelector(step.targetSelector);
    if (!element) {
      // Fallback to center if element not found
      const viewportWidth = window.innerWidth;
      const viewportHeight = window.innerHeight;
      setPosition({
        top: viewportHeight / 2 - 100,
        left: viewportWidth / 2 - TOOLTIP_WIDTH / 2,
      });
      return;
    }

    const rect = element.getBoundingClientRect();
    const padding = step.highlightPadding ?? 8;
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;

    // Highlighted element bounds (with padding)
    const highlightTop = rect.top - padding;
    const highlightBottom = rect.bottom + padding;
    const highlightLeft = rect.left - padding;
    const highlightRight = rect.right + padding;

    // Try placements in order of preference, starting with the specified one
    const placements: Array<"top" | "bottom" | "left" | "right"> =
      step.placement === "top" ? ["top", "bottom", "left", "right"] :
      step.placement === "bottom" ? ["bottom", "top", "left", "right"] :
      step.placement === "left" ? ["left", "right", "top", "bottom"] :
      step.placement === "right" ? ["right", "left", "top", "bottom"] :
      ["bottom", "top", "right", "left"];

    for (const placement of placements) {
      let top = 0;
      let left = 0;
      let arrowPosition: TooltipPosition["arrowPosition"];

      switch (placement) {
        case "bottom":
          top = highlightBottom + TOOLTIP_OFFSET;
          left = rect.left + rect.width / 2 - TOOLTIP_WIDTH / 2;
          arrowPosition = "top";
          break;
        case "top":
          top = highlightTop - TOOLTIP_OFFSET - TOOLTIP_HEIGHT;
          left = rect.left + rect.width / 2 - TOOLTIP_WIDTH / 2;
          arrowPosition = "bottom";
          break;
        case "left":
          top = rect.top + rect.height / 2 - TOOLTIP_HEIGHT / 2;
          left = highlightLeft - TOOLTIP_OFFSET - TOOLTIP_WIDTH;
          arrowPosition = "right";
          break;
        case "right":
          top = rect.top + rect.height / 2 - TOOLTIP_HEIGHT / 2;
          left = highlightRight + TOOLTIP_OFFSET;
          arrowPosition = "left";
          break;
      }

      // Clamp to viewport
      left = Math.max(8, Math.min(left, viewportWidth - TOOLTIP_WIDTH - 8));
      top = Math.max(8, Math.min(top, viewportHeight - TOOLTIP_HEIGHT - 8));

      // Check if tooltip overlaps with highlighted element
      const tooltipBottom = top + TOOLTIP_HEIGHT;
      const tooltipRight = left + TOOLTIP_WIDTH;
      const overlaps = !(
        tooltipBottom < highlightTop ||
        top > highlightBottom ||
        tooltipRight < highlightLeft ||
        left > highlightRight
      );

      if (!overlaps) {
        setPosition({ top, left, arrowPosition });
        return;
      }
    }

    // Fallback: place below and accept overlap
    const top = highlightBottom + TOOLTIP_OFFSET;
    const left = Math.max(8, Math.min(
      rect.left + rect.width / 2 - TOOLTIP_WIDTH / 2,
      viewportWidth - TOOLTIP_WIDTH - 8
    ));
    setPosition({ top, left, arrowPosition: "top" });
  }, [step]);

  useEffect(() => {
    calculatePosition();

    window.addEventListener("scroll", calculatePosition, true);
    window.addEventListener("resize", calculatePosition);

    return () => {
      window.removeEventListener("scroll", calculatePosition, true);
      window.removeEventListener("resize", calculatePosition);
    };
  }, [calculatePosition]);

  // Handle keyboard navigation
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        onSkip();
      } else if (e.key === "ArrowRight" || e.key === "Enter") {
        onNext();
      } else if (e.key === "ArrowLeft" && !isFirstStep) {
        onPrevious();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onNext, onPrevious, onSkip, isFirstStep]);

  const tooltipStyle: CSSProperties = {
    position: "fixed",
    top: position.top,
    left: position.left,
    width: TOOLTIP_WIDTH,
    zIndex: 10000,
    transition: "top 0.3s ease-out, left 0.3s ease-out",
  };

  const arrowStyle: CSSProperties = {
    position: "absolute",
    width: 0,
    height: 0,
    ...(position.arrowPosition === "top" && {
      top: -ARROW_SIZE,
      left: "50%",
      transform: "translateX(-50%)",
      borderLeft: `${ARROW_SIZE}px solid transparent`,
      borderRight: `${ARROW_SIZE}px solid transparent`,
      borderBottom: `${ARROW_SIZE}px solid white`,
    }),
    ...(position.arrowPosition === "bottom" && {
      bottom: -ARROW_SIZE,
      left: "50%",
      transform: "translateX(-50%)",
      borderLeft: `${ARROW_SIZE}px solid transparent`,
      borderRight: `${ARROW_SIZE}px solid transparent`,
      borderTop: `${ARROW_SIZE}px solid white`,
    }),
    ...(position.arrowPosition === "left" && {
      left: -ARROW_SIZE,
      top: "50%",
      transform: "translateY(-50%)",
      borderTop: `${ARROW_SIZE}px solid transparent`,
      borderBottom: `${ARROW_SIZE}px solid transparent`,
      borderRight: `${ARROW_SIZE}px solid white`,
    }),
    ...(position.arrowPosition === "right" && {
      right: -ARROW_SIZE,
      top: "50%",
      transform: "translateY(-50%)",
      borderTop: `${ARROW_SIZE}px solid transparent`,
      borderBottom: `${ARROW_SIZE}px solid transparent`,
      borderLeft: `${ARROW_SIZE}px solid white`,
    }),
  };

  return (
    <div style={tooltipStyle}>
      <div className="relative bg-white dark:bg-neutral-900 rounded-lg shadow-xl border border-neutral-200 dark:border-neutral-800">
        {/* Arrow */}
        {position.arrowPosition && step.placement !== "center" && (
          <div
            style={{
              ...arrowStyle,
              ...(position.arrowPosition === "top" && {
                borderBottomColor: "var(--tooltip-bg, white)",
              }),
              ...(position.arrowPosition === "bottom" && {
                borderTopColor: "var(--tooltip-bg, white)",
              }),
              ...(position.arrowPosition === "left" && {
                borderRightColor: "var(--tooltip-bg, white)",
              }),
              ...(position.arrowPosition === "right" && {
                borderLeftColor: "var(--tooltip-bg, white)",
              }),
            }}
            className="[--tooltip-bg:theme(colors.white)] dark:[--tooltip-bg:theme(colors.neutral.900)]"
          />
        )}

        {/* Header */}
        <div className="flex items-center justify-between px-3 pt-3">
          <span className="text-xs font-medium text-neutral-500 dark:text-neutral-400">
            {currentIndex + 1} / {totalSteps}
          </span>
          <button
            onClick={onSkip}
            className="-m-1 p-1 rounded hover:bg-neutral-100 dark:hover:bg-neutral-800 text-neutral-400 hover:text-neutral-700 dark:hover:text-white transition-colors"
            aria-label="Close"
          >
            <X className="w-3.5 h-3.5" />
          </button>
        </div>

        {/* Content */}
        <div className="px-3 pt-1 pb-3">
          <h3 className="text-sm font-medium text-neutral-900 dark:text-white mb-0.5">
            {step.title}
          </h3>
          <p className="text-xs text-neutral-600 dark:text-neutral-400 leading-relaxed">
            {step.description}
          </p>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between p-3 border-t border-neutral-200 dark:border-neutral-800">
          <button
            onClick={onPrevious}
            disabled={isFirstStep}
            className="flex items-center gap-0.5 text-xs text-neutral-500 dark:text-neutral-400 hover:text-neutral-900 dark:hover:text-white disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
          >
            <ChevronLeft className="w-3 h-3" />
            Back
          </button>
          <div className="flex items-center gap-3">
            <button
              onClick={onSkip}
              className="text-xs text-neutral-500 dark:text-neutral-400 hover:text-neutral-700 dark:hover:text-neutral-200 transition-colors"
            >
              Skip
            </button>
            <button
              onClick={onNext}
              className="flex items-center gap-0.5 px-2 py-1 text-xs font-medium rounded bg-neutral-900 text-white hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200 transition-colors"
            >
              {isLastStep ? "Done" : "Next"}
              {!isLastStep && <ChevronRight className="w-3 h-3" />}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
