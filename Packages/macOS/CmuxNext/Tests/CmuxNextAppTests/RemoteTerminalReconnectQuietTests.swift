import AppKit
@testable import CmuxNextApp
import Testing

/// Leo, 2026-11-24: "all the connecting... indicators and the graying out of workspaces, nah let's not do that.
/// let's just keep optimistically connecting and reinforcing the connection and sync-ups can be satisfying instead
/// of making the user think they're constsntly suspended in a state of connection limbo". A remote terminal tab
/// whose session is reattaching said "Reconnecting to {machine}…" once the reattach lasted 10 s. Now it shows the
/// saved screen alone for as long as the reattach takes; "offline" with Connect, which a person can act on, shows
/// at once.
@MainActor
@Suite struct RemoteTerminalReconnectQuietTests {
    @Test func aReconnectShowsTheSavedScreenAloneForGood() async throws {
        let view = RemoteTerminalPlaceholderView(frame: .zero)
        for _ in 0..<3 {
            view.show(machine: "studio", state: .reconnecting, snapshot: "$ make test")
            #expect(view.statusText.isEmpty, "a reconnect says nothing, at any age")
            #expect(view.snapshotText == "$ make test", "the saved screen draws at once")
            try await Task.sleep(for: .milliseconds(20)) // wakeup-allow: proves no timer turns the line on
        }
    }

    @Test func offlineWithConnectShowsAtOnce() {
        let view = RemoteTerminalPlaceholderView(frame: .zero)
        view.show(machine: "studio", state: .reconnecting, snapshot: nil)
        view.onConnect = {}
        view.show(machine: "studio", state: .offline, snapshot: nil)
        #expect(view.statusText == RemoteStrings.placeholderOffline("studio"))
    }
}
