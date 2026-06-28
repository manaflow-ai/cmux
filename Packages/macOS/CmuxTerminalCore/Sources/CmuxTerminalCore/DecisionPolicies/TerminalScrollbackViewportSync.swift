public import CoreGraphics

extension GhosttyScrollbar {
    /// Whether the viewport's bottom edge sits above the bottom of scrollback,
    /// i.e. the user is reviewing scrollback rather than tailing live output.
    ///
    /// Seeds `userScrolledAwayFromBottom` from the reported geometry when an
    /// explicit wheel scroll's first scrollbar packet arrives (the runtime
    /// reports the new position before the clip view has moved).
    public var isViewportAwayFromBottom: Bool {
        offset + len < total
    }
}

/// Pure viewport-position decisions for a terminal surface's scrollback,
/// drained off `GhosttySurfaceScrollView` in the app target.
///
/// The witness owns every AppKit read and effect: it samples `cellSize`, the
/// live ``GhosttyScrollbar`` packet, the clip-view bounds, and the document
/// height; runs the `isLiveScrolling` / `cellHeight > 0` guards; performs the
/// `NSClipView.scroll(to:)` and `scroll_to_row:` side effects; and stores the
/// `userScrolledAwayFromBottom`, `allowExplicitScrollbarSync`, and `lastSentRow`
/// latches. It hands the sampled geometry to this type and gets back the
/// deterministic position arithmetic plus the next "scrolled away from bottom"
/// latch, so the math stays testable and references no AppKit.
public enum TerminalScrollbackViewportSync: Sendable {
    /// Decision for a passive scrollbar packet (`synchronizeScrollView`).
    public struct AutoScrollDecision: Sendable, Equatable {
        /// The document-space y origin the clip view should scroll to so the
        /// reported scrollback offset sits at the top of the viewport.
        public let targetOffsetY: CGFloat
        /// Whether the clip view currently sits at the bottom (within the
        /// caller's drift threshold).
        public let isAtBottom: Bool
        /// The next value of the witness's `userScrolledAwayFromBottom` latch:
        /// cleared when at bottom, otherwise unchanged.
        public let scrolledAwayFromBottom: Bool
        /// Whether the witness should move the clip view to `targetOffsetY`.
        public let shouldAutoScroll: Bool

        public init(
            targetOffsetY: CGFloat,
            isAtBottom: Bool,
            scrolledAwayFromBottom: Bool,
            shouldAutoScroll: Bool
        ) {
            self.targetOffsetY = targetOffsetY
            self.isAtBottom = isAtBottom
            self.scrolledAwayFromBottom = scrolledAwayFromBottom
            self.shouldAutoScroll = shouldAutoScroll
        }
    }

    /// Resolves the auto-scroll decision for a passive scrollbar packet.
    ///
    /// Mirrors the arithmetic that lived in
    /// `GhosttySurfaceScrollView.synchronizeScrollView()`: the target offset is
    /// the rows below the viewport (`total - offset - len`) times the cell
    /// height, "at bottom" is measured against the live clip origin, and an
    /// at-bottom packet clears the scrolled-away latch. A passive packet only
    /// re-pins the viewport when the user has not scrolled away, unless the
    /// caller's one-shot `allowExplicitScrollbarSync` overrides it for the first
    /// packet caused by the user's own wheel input.
    public static func autoScrollDecision(
        scrollbar: GhosttyScrollbar,
        cellHeight: CGFloat,
        currentOriginY: CGFloat,
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        scrolledAwayFromBottom: Bool,
        allowExplicitScrollbarSync: Bool,
        bottomThreshold: CGFloat
    ) -> AutoScrollDecision {
        let offsetY = CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
        let distanceFromBottom = documentHeight - currentOriginY - viewportHeight
        let isAtBottom = distanceFromBottom <= bottomThreshold
        let nextScrolledAway = isAtBottom ? false : scrolledAwayFromBottom
        let shouldAutoScroll = !nextScrolledAway || allowExplicitScrollbarSync
        return AutoScrollDecision(
            targetOffsetY: offsetY,
            isAtBottom: isAtBottom,
            scrolledAwayFromBottom: nextScrolledAway,
            shouldAutoScroll: shouldAutoScroll
        )
    }

    /// Decision for a live user drag of the scroller (`handleLiveScroll`).
    public struct LiveScrollDecision: Sendable, Equatable {
        /// The scrollback row the witness should request via `scroll_to_row:`.
        /// Computed as `floor(scrollOffset / cellHeight)`.
        public let row: Int
        /// The next value of the witness's `userScrolledAwayFromBottom` latch.
        public let scrolledAwayFromBottom: Bool

        public init(row: Int, scrolledAwayFromBottom: Bool) {
            self.row = row
            self.scrolledAwayFromBottom = scrolledAwayFromBottom
        }
    }

    /// Resolves the live-scroll decision while the user drags the scroller.
    ///
    /// Mirrors `GhosttySurfaceScrollView.handleLiveScroll()`: the scrollback
    /// offset is the document height minus the visible rect's far edge; dragging
    /// past the drift threshold latches "scrolled away", and returning to (or
    /// past) the bottom clears it. The witness still owns the `cellHeight > 0`
    /// guard, the `row == lastSentRow` dedupe, and the `scroll_to_row:` effect.
    public static func liveScrollDecision(
        cellHeight: CGFloat,
        documentHeight: CGFloat,
        visibleOriginY: CGFloat,
        visibleHeight: CGFloat,
        scrolledAwayFromBottom: Bool,
        bottomThreshold: CGFloat
    ) -> LiveScrollDecision {
        let scrollOffset = documentHeight - visibleOriginY - visibleHeight
        let nextScrolledAway: Bool
        if scrollOffset > bottomThreshold {
            nextScrolledAway = true
        } else if scrollOffset <= 0 {
            nextScrolledAway = false
        } else {
            nextScrolledAway = scrolledAwayFromBottom
        }
        let row = Int(scrollOffset / cellHeight)
        return LiveScrollDecision(row: row, scrolledAwayFromBottom: nextScrolledAway)
    }
}
