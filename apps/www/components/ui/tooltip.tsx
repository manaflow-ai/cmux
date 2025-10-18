import * as TooltipPrimitive from "@radix-ui/react-tooltip"
import { memo } from "react"
import type { ComponentProps, CSSProperties } from "react"

import { cn } from "@/lib/utils"

const TooltipProvider = memo(function TooltipProvider(
  props: ComponentProps<typeof TooltipPrimitive.Provider>
) {
  return <TooltipPrimitive.Provider data-slot="tooltip-provider" {...props} />
})

function Tooltip(props: ComponentProps<typeof TooltipPrimitive.Root>) {
  return <TooltipPrimitive.Root data-slot="tooltip" {...props} />
}

function TooltipTrigger(props: ComponentProps<typeof TooltipPrimitive.Trigger>) {
  return <TooltipPrimitive.Trigger data-slot="tooltip-trigger" {...props} />
}

function TooltipContent({
  className,
  sideOffset = 4,
  children,
  ...props
}: ComponentProps<typeof TooltipPrimitive.Content>) {
  return (
    <TooltipPrimitive.Portal>
      <TooltipPrimitive.Content
        data-slot="tooltip-content"
        sideOffset={sideOffset}
        style={{ "--primary": "black" } as CSSProperties}
        className={cn(
          "z-[var(--z-modal)] w-fit pointer-events-none select-none rounded-md bg-primary px-3 py-2 text-xs text-primary-foreground shadow-sm",
          "data-[state=delayed-open]:animate-in data-[state=delayed-open]:fade-in-0 data-[state=delayed-open]:zoom-in-95",
          "data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-95",
          "data-[state=delayed-open]:data-[side=bottom]:slide-in-from-top-2 data-[state=delayed-open]:data-[side=top]:slide-in-from-bottom-2 data-[state=delayed-open]:data-[side=left]:slide-in-from-right-2 data-[state=delayed-open]:data-[side=right]:slide-in-from-left-2",
          className
        )}
        {...props}
      >
        {children}
        <TooltipPrimitive.Arrow className="size-2.5 translate-y-[calc(-50%_-_2px)] rotate-45 rounded-[2px] bg-primary fill-primary text-primary pointer-events-none select-none" />
      </TooltipPrimitive.Content>
    </TooltipPrimitive.Portal>
  )
}

export { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger }
