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
    ///
    /// Runtime-backed wheel input requires the synchronous snapshot taken
    /// after forwarding the event. Callers without that runtime seam may use
    /// the legacy, unmarked mode; runtime teardown cancels the request instead
    /// of applying an identity-less stale packet.
    case awaitingExplicitScrollbarSync(
        previousWasReviewing: Bool,
        requiresAuthoritativeResponse: Bool
    )

    /// Whether the viewport is currently reviewing historical scrollback.
    public var isReviewingScrollback: Bool {
        switch self {
        case .followingOutput:
            return false
        case .reviewingScrollback:
            return true
        case .awaitingExplicitScrollbarSync(let previousWasReviewing, _):
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

    /// Whether passive packets must wait for a marked runtime response.
    private var requiresAuthoritativeScrollbarResponse: Bool {
        guard case .awaitingExplicitScrollbarSync(_, let requiresAuthoritativeResponse) = self else {
            return false
        }
        return requiresAuthoritativeResponse
    }

    /// Whether layout must preserve the wrapper viewport while intent is unresolved.
    public var preservesViewportDuringPendingSync: Bool {
        isReviewingScrollback || isAwaitingExplicitScrollbarSync
    }

    /// Whether a passive runtime packet may move the AppKit viewport.
    ///
    /// An explicit packet is handled through
    /// ``applyingScrollbar(_:targetDistanceFromBottom:bottomThreshold:isAuthoritativeWheelResponse:)``;
    /// an unresolved explicit request must not make a stale packet from a
    /// layout pass move the wrapper.
    public var allowsPassiveScrollbarSync: Bool {
        self == .followingOutput
    }

    /// Arms the synchronization window opened by a user wheel gesture.
    ///
    /// - Parameter requiresAuthoritativeResponse: Whether passive packets must
    ///   wait for a marked snapshot read directly after the wheel input.
    public func beginningExplicitScrollbarSync(
        requiresAuthoritativeResponse: Bool = false
    ) -> Self {
        guard !isAwaitingExplicitScrollbarSync else {
            return requiresAuthoritativeResponse
                ? upgradingToAuthoritativeScrollbarResponse()
                : self
        }
        return .awaitingExplicitScrollbarSync(
            previousWasReviewing: isReviewingScrollback,
            requiresAuthoritativeResponse: requiresAuthoritativeResponse
        )
    }

    private func upgradingToAuthoritativeScrollbarResponse() -> Self {
        guard case .awaitingExplicitScrollbarSync(let previousWasReviewing, false) = self else {
            return self
        }
        return .awaitingExplicitScrollbarSync(
            previousWasReviewing: previousWasReviewing,
            requiresAuthoritativeResponse: true
        )
    }

    /// Cancels a wheel request when the runtime cannot provide its snapshot.
    ///
    /// The prior follow/review intent is restored so teardown cannot leave the
    /// viewport permanently blocked waiting for a packet that will never come.
    public func cancellingExplicitScrollbarSync() -> Self {
        guard case .awaitingExplicitScrollbarSync(let previousWasReviewing, _) = self else {
            return self
        }
        return previousWasReviewing ? .reviewingScrollback : .followingOutput
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
    ///
    /// - Parameters:
    ///   - scrollbar: The scrollbar geometry being considered.
    ///   - targetDistanceFromBottom: The wrapper target's distance from the
    ///     live bottom, or `nil` when pixel geometry is unavailable.
    ///   - bottomThreshold: The maximum target distance treated as live bottom.
    ///   - isAuthoritativeWheelResponse: Whether this snapshot was read
    ///     synchronously after forwarding the pending wheel input.
    /// - Returns: The next intent and whether the wrapper should synchronize.
    public func applyingScrollbar(
        _ scrollbar: GhosttyScrollbar,
        targetDistanceFromBottom: Double?,
        bottomThreshold: Double,
        isAuthoritativeWheelResponse: Bool = false
    ) -> TerminalScrollbackScrollbarSyncDecision {
        let isExplicit = isAwaitingExplicitScrollbarSync
        let canConsumeExplicitSync = isExplicit &&
            (!requiresAuthoritativeScrollbarResponse || isAuthoritativeWheelResponse)
        let shouldSynchronize: Bool
        if isExplicit && !canConsumeExplicitSync {
            // Do not let an identity-less packet from before the wheel move
            // the wrapper or consume the pending explicit response.
            shouldSynchronize = false
        } else {
            shouldSynchronize = canConsumeExplicitSync ||
                allowsPassiveScrollbarSync ||
                !scrollbar.isAtBottom
        }

        let nextIntent: Self
        if canConsumeExplicitSync {
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
            consumedExplicitSync: canConsumeExplicitSync
        )
    }
}
