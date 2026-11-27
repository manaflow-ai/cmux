#if os(iOS)
import CmuxMobileDesign
@testable import CmuxMobileShell
import SwiftUI
import Testing
import UIKit

/// Leo, 2026-11-24 (item 3): "all the connecting... indicators ... nah let's not do that. let's
/// just keep optimistically connecting and reinforcing the connection". The wait for a Cloud
/// machine's chats takes no room and draws no words; the timeout still says why, with
/// the quiet auto-retry line (no Retry button since #50367).
///
/// Fails on feat-cmux-next before this change: there the wait drew a spinner, "Connecting to
/// <machine> through <Mac>…" and "Up to 40 s" (placeholder `cloud.chat.connecting`).
@MainActor struct CloudChatsNoConnectingTests {
    private static func size(_ view: some View) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 402, height: 800))
    }

    @Test func theCloudWaitDrawsNothing() {
        #expect(Self.size(CloudChatsConnecting()) == .zero)
    }

    @Test func theTimeoutStillSaysWhy() {
        #expect(Self.size(CloudChatsConnectFailed(cause: "No answer from atlas-dev in 40 s.", autoRetry: AutoRetry())).height > 0)
    }
}
#endif
