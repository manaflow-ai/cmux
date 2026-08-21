import Testing
import CmuxTerminalCore

@Suite struct TerminalScrollbackViewportIntentTests {
    @Test func reviewingScrollbackSuppressesPassiveBottomPacket() {
        let decision = TerminalScrollbackViewportIntent.reviewingScrollback
            .applyingScrollbar(
                scrollbar(total: 100, offset: 90, visible: 10),
                targetDistanceFromBottom: 0,
                bottomThreshold: 5
            )

        #expect(decision.intent == .reviewingScrollback)
        #expect(!decision.shouldSynchronizeViewport)
        #expect(!decision.consumedExplicitSync)
    }

    @Test func reviewingScrollbackAcceptsAuthoritativeReflowPacket() {
        let decision = TerminalScrollbackViewportIntent.reviewingScrollback
            .applyingScrollbar(
                scrollbar(total: 120, offset: 50, visible: 10),
                targetDistanceFromBottom: 600,
                bottomThreshold: 5
            )

        #expect(decision.intent == .reviewingScrollback)
        #expect(decision.shouldSynchronizeViewport)
    }

    @Test func userScrollUsesNonFlippedBottomDistance() {
        let reviewing = TerminalScrollbackViewportIntent.followingOutput
            .applyingUserScroll(distanceFromBottom: 200, bottomThreshold: 5)
        #expect(reviewing == .reviewingScrollback)

        let following = reviewing.applyingUserScroll(
            distanceFromBottom: 2,
            bottomThreshold: 5
        )
        #expect(following == .followingOutput)
    }

    @Test func explicitWheelPacketResolvesIntentFromTargetViewport() {
        let pending = TerminalScrollbackViewportIntent.reviewingScrollback
            .beginningExplicitScrollbarSync()
        #expect(pending.isAwaitingExplicitScrollbarSync)

        let decision = pending.applyingScrollbar(
            scrollbar(total: 100, offset: 40, visible: 10),
            targetDistanceFromBottom: 500,
            bottomThreshold: 5
        )

        #expect(decision.intent == .reviewingScrollback)
        #expect(decision.shouldSynchronizeViewport)
        #expect(decision.consumedExplicitSync)
    }

    @Test func authoritativeWheelSyncIgnoresUnmarkedPacketsUntilResponse() {
        let pending = TerminalScrollbackViewportIntent.followingOutput
            .beginningExplicitScrollbarSync(requiresAuthoritativeResponse: true)
        let staleDecision = pending.applyingScrollbar(
            scrollbar(total: 100, offset: 40, visible: 10),
            targetDistanceFromBottom: 500,
            bottomThreshold: 5
        )

        #expect(staleDecision.intent == pending)
        #expect(!staleDecision.shouldSynchronizeViewport)
        #expect(!staleDecision.consumedExplicitSync)

        let responseDecision = staleDecision.intent.applyingScrollbar(
            scrollbar(total: 100, offset: 90, visible: 10),
            targetDistanceFromBottom: 0,
            bottomThreshold: 5,
            isAuthoritativeWheelResponse: true
        )

        #expect(responseDecision.intent == .followingOutput)
        #expect(responseDecision.shouldSynchronizeViewport)
        #expect(responseDecision.consumedExplicitSync)
    }

    @Test func liveWheelUpgradesPendingLegacySyncToAuthoritativeResponse() {
        let pending = TerminalScrollbackViewportIntent.followingOutput
            .beginningExplicitScrollbarSync()
            .beginningExplicitScrollbarSync(requiresAuthoritativeResponse: true)
        let passiveDecision = pending.applyingScrollbar(
            scrollbar(total: 100, offset: 40, visible: 10),
            targetDistanceFromBottom: 500,
            bottomThreshold: 5
        )

        #expect(passiveDecision.intent == pending)
        #expect(!passiveDecision.shouldSynchronizeViewport)
        #expect(!passiveDecision.consumedExplicitSync)
    }

    @Test func unavailableAuthoritativeResponseCancelsPendingSync() {
        let pending = TerminalScrollbackViewportIntent.reviewingScrollback
            .beginningExplicitScrollbarSync(requiresAuthoritativeResponse: true)

        #expect(pending.cancellingExplicitScrollbarSync() == .reviewingScrollback)
    }

    @Test func scrollbarBottomCheckUsesClampedTopRow() {
        #expect(scrollbar(total: 100, offset: 90, visible: 10).isAtBottom)
        #expect(!scrollbar(total: 100, offset: 89, visible: 10).isAtBottom)
        #expect(scrollbar(total: 100, offset: 500, visible: 10).isAtBottom)
    }

    private func scrollbar(
        total: UInt64,
        offset: UInt64,
        visible: UInt64
    ) -> GhosttyScrollbar {
        GhosttyScrollbar(total: total, offset: offset, len: visible)
    }
}
