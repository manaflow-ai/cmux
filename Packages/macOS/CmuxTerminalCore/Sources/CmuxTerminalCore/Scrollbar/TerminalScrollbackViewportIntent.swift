/// The user's terminal scroll intent, independent of transient AppKit geometry.
///
/// A non-flipped ``NSClipView`` reports the live bottom at `origin.y == 0`,
/// while Ghostty reports scrollbar offsets from the top. Keeping this state
/// separate from either coordinate system prevents layout/reflow from being
/// mistaken for an explicit user scroll.
public enum TerminalScrollbackViewportIntent: Equatable, Sendable {
    /// The viewport follows newly produced terminal output at the live bottom.
    case followingOutput

    /// The user is reviewing historical scrollback and output must not yank it away.
    case reviewingScrollback

    /// A user gesture is waiting for its authoritative Ghostty scrollbar packet.
    case awaitingExplicitScrollbarSync(previousWasReviewing: Bool)

    /// Whether the viewport is currently reviewing historical scrollback.
    public var isReviewingScrollback: Bool {
        switch self {
        case .followingOutput:
            return false
        case .reviewingScrollback:
            return true
        case .awaitingExplicitScrollbarSync(let previousWasReviewing):
            return previousWasReviewing
        }
    }

    /// Whether an explicit scrollbar packet is still outstanding.
    public var isAwaitingExplicitScrollbarSync: Bool {
        if case .awaitingExplicitScrollbarSync = self {
            return true
        }
        return false
    }

    /// Whether a passive runtime packet may move the AppKit viewport.
    ///
    /// An explicit packet is handled through ``applyingScrollbar(_:targetDistanceFromBottom:bottomThreshold:)``;
    /// an unresolved explicit request must not make a stale packet from a
    /// layout pass move the wrapper.
    public var allowsPassiveScrollbarSync: Bool {
        self == .followingOutput
    }

    /// Arms the one-packet window opened by a user wheel gesture.
    public func beginningExplicitScrollbarSync() -> Self {
        guard !isAwaitingExplicitScrollbarSync else { return self }
        return .awaitingExplicitScrollbarSync(
            previousWasReviewing: isReviewingScrollback
        )
    }

    /// Updates intent from an actual user-driven AppKit scroll gesture.
    ///
    /// This method must not be called from layout or document-size updates.
    public func applyingUserScroll(
        distanceFromBottom: Double,
        bottomThreshold: Double
    ) -> Self {
        guard !isAwaitingExplicitScrollbarSync,
              distanceFromBottom.isFinite else {
            return self
        }
        return distanceFromBottom > bottomThreshold
            ? .reviewingScrollback
            : .followingOutput
    }

    /// Resolves a direct, programmatic viewport restore (for example a saved
    /// notification position) without waiting for a passive packet.
    public func resolvingExplicitViewportRestore(isAtBottom: Bool) -> Self {
        isAtBottom ? .followingOutput : .reviewingScrollback
    }

    /// Decides whether an authoritative Ghostty scrollbar packet should update
    /// the AppKit wrapper and resolves an outstanding explicit wheel request.
    public func applyingScrollbar(
        _ scrollbar: GhosttyScrollbar,
        targetDistanceFromBottom: Double?,
        bottomThreshold: Double
    ) -> TerminalScrollbackScrollbarSyncDecision {
        let isExplicit = isAwaitingExplicitScrollbarSync
        let shouldSynchronize = isExplicit ||
            allowsPassiveScrollbarSync ||
            !scrollbar.isAtBottom

        let nextIntent: Self
        if isExplicit {
            let targetIsAtBottom: Bool
            if let targetDistanceFromBottom,
               targetDistanceFromBottom.isFinite {
                targetIsAtBottom = targetDistanceFromBottom <= bottomThreshold
            } else {
                targetIsAtBottom = scrollbar.isAtBottom
            }
            nextIntent = resolvingExplicitViewportRestore(isAtBottom: targetIsAtBottom)
        } else {
            nextIntent = self
        }

        return TerminalScrollbackScrollbarSyncDecision(
            intent: nextIntent,
            shouldSynchronizeViewport: shouldSynchronize,
            consumedExplicitSync: isExplicit
        )
    }
}

/// The decision produced for one authoritative Ghostty scrollbar packet.
public struct TerminalScrollbackScrollbarSyncDecision: Equatable, Sendable {
    /// The intent to retain after processing the packet.
    public let intent: TerminalScrollbackViewportIntent

    /// Whether the AppKit viewport should be moved to the packet's position.
    public let shouldSynchronizeViewport: Bool

    /// Whether this packet consumed a pending explicit user-scroll request.
    public let consumedExplicitSync: Bool

    /// Creates a packet synchronization decision.
    ///
    /// - Parameters:
    ///   - intent: The intent to retain after processing the packet.
    ///   - shouldSynchronizeViewport: Whether AppKit should adopt the packet's viewport.
    ///   - consumedExplicitSync: Whether the packet resolved an explicit request.
    public init(
        intent: TerminalScrollbackViewportIntent,
        shouldSynchronizeViewport: Bool,
        consumedExplicitSync: Bool
    ) {
        self.intent = intent
        self.shouldSynchronizeViewport = shouldSynchronizeViewport
        self.consumedExplicitSync = consumedExplicitSync
    }
}

extension GhosttyScrollbar {
    /// Rows between the viewport's bottom edge and the live bottom.
    public var rowsBelowViewport: UInt64 {
        let visibleRows = min(total, len)
        let lastTopRow = total >= visibleRows ? total - visibleRows : 0
        let topRow = min(offset, lastTopRow)
        return lastTopRow - topRow
    }

    /// Whether the viewport reaches the live bottom of scrollback.
    public var isAtBottom: Bool {
        rowsBelowViewport == 0
    }
}
