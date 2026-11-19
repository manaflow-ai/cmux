import AppKit
@testable import CmuxNextApp
import Testing

/// Automatic reconnect never speaks over the saved screen; a stopped connection still offers Connect.
@MainActor
@Suite struct RemoteTerminalReconnectQuietTests {
    @Test func aReconnectRendersNoLineAndKeepsTheLastFrame() {
        let view = RemoteTerminalPlaceholderView(frame: .zero)
        view.show(machine: "studio", state: .reconnecting, snapshot: "$ make test")
        #expect(view.statusText.isEmpty)
        #expect(view.snapshotText == "$ make test")
        #expect(view.accessibilityLabel()?.isEmpty == true)
        view.show(machine: "studio", state: .reconnecting, snapshot: "$ make test")
        #expect(view.statusText.isEmpty, "repeated recovery updates stay quiet")
    }

    @Test func offlineWithConnectStillOffersTheAction() {
        let view = RemoteTerminalPlaceholderView(frame: .zero)
        view.show(machine: "studio", state: .reconnecting, snapshot: "$ make test")
        view.onConnect = {}
        view.show(machine: "studio", state: .offline, snapshot: "$ make test")
        #expect(view.statusText == RemoteStrings.placeholderOffline("studio"))
        #expect(view.snapshotText == "$ make test")
    }
}
