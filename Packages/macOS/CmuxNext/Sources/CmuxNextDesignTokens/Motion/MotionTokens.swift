public import Foundation

/// How fast chrome animates (`ui.animationSpeed` in cmux.json).
public nonisolated enum MotionSpeed: String, Sendable, CaseIterable, Codable {
    /// The default: short springs tuned for a pro tool (plans/cmux-next/motion.md).
    case fast
    /// About Apple's system pacing: every duration is 1.5 times longer.
    case normal
    /// No animation. Every change applies in one frame.
    case off

    /// Multiplier on every spring response and fade duration.
    public var timeScale: Double {
        switch self {
        case .fast: 1
        case .normal: 1.5
        case .off: 0
        }
    }
}

/// Spring tokens. Each one is a response (seconds for one undamped period)
/// and a damping fraction (1 = critically damped), as in SwiftUI
/// `.spring(response:dampingFraction:)`. The structural ones (`move`,
/// `appear`, `disappear`) are critically damped with a short response
/// (they never pass the target; `ui.animations.bounce` subtle opts into a
/// SwiftUI bounce). The values are the spec's design-tokens.json `motion`
/// (cmux-motion reads the same file; scripts/cmux-next/motion-parity.py
/// compares this port's paths with cmux-motion's). The cases are declared
/// in cmux-motion's `MotionSpring::ALL` order, the token index of its C ABI
/// (`cmux_motion_spring_base`): append new tokens on both sides.
public nonisolated enum MotionSpring: String, Sendable, CaseIterable {
    /// An existing item moves or resizes: tab reflow and reorder, sidebar
    /// rows, pane and divider frames, pane unzoom, toolbar height.
    case move
    /// Something appears or expands: tab grow-in, group expand, row insert,
    /// sidebar show.
    case appear
    /// Something disappears or collapses: tab close, group collapse,
    /// sidebar hide. Faster than `appear`.
    case disappear
    /// Release after direct manipulation (drop, drag cancel, ghost landing).
    /// Slightly under-damped so the carried velocity reads as physical.
    case settle
    /// Programmatic scroll: tab strip reveal, strip column reveal, wheel
    /// notch, trackpad fling snap. Response 0.2 s (stiffness about 990;
    /// 0.222 s until Leo 2026-10-20's shorter scale); damping 0.9 instead of
    /// 1 drops the slow sub-pixel tail.
    case scroll
    /// Screen switch slide.
    case screen
    /// An overlay that tracks the pointer between targets: drop zones, the
    /// drag ghost's jump between card and inline slot.
    case track
    /// Selection indicator glide (sidebar pill).
    case selection
    /// Floating panel open: palette scale-in, hover card slide.
    case panel
    /// Home list pin drag: tiles making room, rows below the grid, a dropped
    /// tile landing (MessagesLab `SidebarPinDragging.spring`).
    case pinDrag
    /// A pane zooming to fill its screen and back: it owns the motion and
    /// covers the other panes (Leo 2026-10-13, Lawrence 2026-10-18).
    case zoom
    /// A pane closing: the neighbours that take its space grow over it, with
    /// their dividers, on this one spring (Lawrence 2026-10-18).
    case exit
    /// A new tab growing in at its final slot while the tabs right of it make room, on one
    /// spring (`ui.animations.newTab`, on by default). Structural.
    case tabOpen
    /// A split (Cmd-D, Cmd-Shift-D): the new pane grows in from the split edge while every pane
    /// of its chain gives up room, one spring from the key's frame to rest (Lawrence 2026-10-19:
    /// "resize all of them while adding a new one"). Slightly under-damped (0.95): no visible
    /// overshoot, a shorter tail than critical damping. Not structural: the bounce setting does
    /// not change it. Swift-only for now (cmux-motion's `MotionSpring` ends at `tabOpen`; parity
    /// compares the tokens both ports have).
    case split
    /// A popup (a popover, a menu, a group editor) growing out of the control it opened from:
    /// scale and fade on the card's own layer (``NSWindow/openPopup(pivot:)``). Slightly
    /// under-damped, like `NSPopover`. Swift-only, like `split`.
    case popover
    /// The same popup shrinking back toward its control as it fades out, faster than it opened.
    /// Critically damped. Swift-only.
    case popoverClose

    /// Values at `MotionSpeed.fast`: the code default (`MotionTunables`),
    /// or its Debug Settings override in DEV and NIGHTLY builds.
    public var base: SpringParameters {
        MotionTunables.springs[self]?.value ?? SpringParameters(response: 0.2, dampingFraction: 0.9)
    }
}

