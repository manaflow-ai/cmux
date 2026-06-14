import CoreGraphics

private extension GhosttyScrollbar {
    var isAtBottom: Bool {
        offset >= total || len >= total - offset
    }
}

enum TerminalScrollbackViewportIntent: Equatable {
    case followOutput
    case reviewingScrollback
    case awaitingExplicitScrollPacket(TerminalScrollbackExplicitScrollPacketExpectation)

    var isFollowingOutput: Bool {
        guard case .followOutput = self else {
            return false
        }
        return true
    }

    var isAwaitingExplicitScrollPacket: Bool {
        guard case .awaitingExplicitScrollPacket = self else {
            return false
        }
        return true
    }

    func applyingLiveScroll(distanceFromBottom: CGFloat, bottomThreshold: CGFloat) -> Self {
        guard !isAwaitingExplicitScrollPacket else {
            return self
        }
        guard distanceFromBottom.isFinite else {
            return self
        }
        return distanceFromBottom > bottomThreshold ? .reviewingScrollback : .followOutput
    }

    func scrollbarSyncDecision(for scrollbar: GhosttyScrollbar) -> TerminalScrollbackScrollbarSyncDecision {
        let allowExplicitScrollbarSync: Bool = {
            switch self {
            case .awaitingExplicitScrollPacket(.any):
                return true
            case .awaitingExplicitScrollPacket(.bottom):
                return scrollbar.isAtBottom
            case .followOutput, .reviewingScrollback:
                return false
            }
        }()
        let nextIntent: Self = {
            guard allowExplicitScrollbarSync else {
                return self
            }
            return scrollbar.isAtBottom ? .followOutput : .reviewingScrollback
        }()
        return TerminalScrollbackScrollbarSyncDecision(
            intent: nextIntent,
            allowExplicitScrollbarSync: allowExplicitScrollbarSync,
            shouldSynchronizeViewport: shouldSynchronizeViewport(
                for: scrollbar,
                allowExplicitScrollbarSync: allowExplicitScrollbarSync
            )
        )
    }

    func shouldSynchronizeViewport(
        for scrollbar: GhosttyScrollbar,
        allowExplicitScrollbarSync: Bool
    ) -> Bool {
        // While reviewing scrollback, still honor non-bottom scrollbar packets so
        // streaming output and resize changes preserve the same visible terminal rows.
        // Suppress only passive bottom packets that would resume follow mode without
        // an explicit user scroll request.
        allowExplicitScrollbarSync || isFollowingOutput || !scrollbar.isAtBottom
    }
}
