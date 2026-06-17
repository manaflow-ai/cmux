import CmuxAgentChat
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// CmuxMobileShellUI is UIKit-bound and iOS-only; its behavior is exercised by
/// the app build and the lower-layer packages' suites. This smoke test keeps the
/// test target valid for simulator-destination CI runs.
@Suite struct CmuxMobileShellUISmokeTests {
    @Test func moduleLinks() {
        #expect(Bool(true))
    }

    @Test func pinnedChatCandidatesStopUsingSeedsAfterLiveSessionsLoad() {
        let seeded = Self.session("seeded", terminalID: "terminal-seeded")
        let live = Self.session("live", terminalID: "terminal-live")

        let firstPaint = WorkspaceDetailView.pinnedChatSessionCandidates(
            current: [],
            liveSessionsAreCurrent: false,
            seeded: [seeded]
        )
        let authoritative = WorkspaceDetailView.pinnedChatSessionCandidates(
            current: [live],
            liveSessionsAreCurrent: true,
            seeded: [seeded]
        )

        #expect(firstPaint.map(\.id) == ["seeded"])
        #expect(authoritative.map(\.id) == ["live"])
    }

    private static func session(_ id: String, terminalID: String) -> ChatSessionDescriptor {
        ChatSessionDescriptor(
            id: id,
            agentKind: .claude,
            title: id,
            workspaceID: "workspace",
            terminalID: terminalID,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 1_781_000_000)
        )
    }
}
