#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileShell

/// The consent prompt follows the standard iOS alert shape so it remains usable
/// above whichever sheet or file picker currently owns the app.
@MainActor @Suite struct MeteredBulkAlertTests {
    @Test func controllerShowsBytesAndTheTwoConsentChoices() {
        var sent = false
        var waited = false
        let alert = MeteredBulkAlert.controller(
            waitingBytes: 2_500_000,
            send: { sent = true },
            wait: { waited = true }
        )

        #expect(alert.preferredStyle == .alert)
        #expect(alert.title == "Send 2.5 MB over cellular?")
        #expect(alert.actions.map(\.title) == ["Send", "Wait for Wi-Fi"])
        #expect(alert.actions.map(\.style) == [.default, .cancel])
        #expect(!sent && !waited)
    }
}
#endif
