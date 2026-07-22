import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite struct PendingReplyStateTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func latestReplyReplacesThePreviouslyParkedReply() {
        var state = PendingReplyState()
        state.park(reply(text: "first"))
        state.park(reply(text: "second"))

        #expect(state.pending?.text == "second")
    }

    @Test func replyExpiresAtTheLifetimeBoundary() {
        var state = PendingReplyState()
        state.park(reply(text: "expired", createdAt: now.addingTimeInterval(-120)))

        #expect(
            state.evaluate(
                now: now,
                isStoreBound: true,
                isTargetReachable: true,
                isChannelAvailable: true
            ) == .expired
        )
        #expect(state.pending == nil)
    }

    @Test(arguments: [
        (false, true, true),
        (true, false, true),
        (true, true, false),
    ])
    func replyWaitsUntilEveryApplyConditionIsReady(
        isStoreBound: Bool,
        isTargetReachable: Bool,
        isChannelAvailable: Bool
    ) {
        var state = PendingReplyState()
        state.park(reply(text: "waiting"))

        #expect(
            state.evaluate(
                now: now,
                isStoreBound: isStoreBound,
                isTargetReachable: isTargetReachable,
                isChannelAvailable: isChannelAvailable
            ) == .waiting
        )
        #expect(state.pending?.text == "waiting")
    }

    @Test func readyReplyIsReturnedAndRemovedFromParking() {
        var state = PendingReplyState()
        let pending = reply(text: "send")
        state.park(pending)

        #expect(
            state.evaluate(
                now: now,
                isStoreBound: true,
                isTargetReachable: true,
                isChannelAvailable: true
            ) == .ready(pending)
        )
        #expect(state.pending == nil)
    }

    private func reply(
        text: String,
        createdAt: Date? = nil
    ) -> PendingReply {
        PendingReply(
            text: text,
            workspaceId: "workspace-1",
            surfaceId: "surface-1",
            macDeviceId: "mac-1",
            retargetsToLiveSurfaceOwner: true,
            createdAt: createdAt ?? now
        )
    }
}
