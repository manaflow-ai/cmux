import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// REOPEN-CLOSED on a daemon that serves the closed history (every real
/// cmux-tui since closed-history-v2): the undo toast of a user close shows
/// once the daemon's closed item for that pane arrives on session.events,
/// as nxdog47 runs it (the app tracker records nothing for such a daemon).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CloseUndoToastDaemonTests {
    static func closedDelta(id: String, indexes: [Int]) -> String {
        let members = indexes.map { index in
            #"{"kind":"tab","name":"t\#(index)","workspace_id":"ws_w","pane_id":"pane_p","index":\#(index),"screens":[{"name":null,"tabs":[{"kind":"terminal","name":"t\#(index)","cwd":"/tmp","url":null,"browser_profile_id":null,"pinned":false}]}]}"#
        }
        let value = #"{"id":"\#(id)","kind":"tab","name":"t","workspace_id":"ws_w","pane_id":"pane_p","index":\#(indexes[0]),"closed_at_ms":"9","screens":[],"window":null,"member_count":\#(indexes.count),"members":[\#(members.joined(separator: ","))]}"#
        return #"{"protocol":"cmux.protocol/2","type":"stream_item","stream_id":"stream_1","sequence":"5","item":{"kind":"delta","cursor":{"generation":"g","revision":"9"},"previous_revision":"1","revision":"9","changes":[{"kind":"state_upsert","sequence":0,"resource":"closed","id":"\#(id)","value":\#(value)}]}}"#
    }

    @Test func aUserCloseOnAStateDaemonShowsTheUndoToast() async throws {
        let daemon = try StateDaemon(state: #"{"closed":[]}"#)
        defer { daemon.stop() }
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.start(makeConnection: { daemon.connection() })
        defer { services.daemon.shutdownConnection() }
        try await waitForCondition("state daemon loaded", timeout: .seconds(10), sourceLocation: #_sourceLocation) {
            services.daemon.store.isLoaded && services.daemon.store.servesStateResources && services.daemon.store.session.known
        }
        let toasts = CmuxToastCenter(clock: ManualClock(), host: CmuxToastHeadlessHost())
        let undo = try #require(services.closedTabs?.undoToasts)
        undo.toasts = toasts
        let pane = try #require(services.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).first)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        undo.expectGroup(tabs: Array(pane.tabs.prefix(1)), in: pane, daemon: services.daemon, window: window)
        let line = Self.closedDelta(id: "closed_new", indexes: [0])
        services.daemon.store.apply(batch: [DaemonEventEnvelope(sequence: 1000, event: DaemonEvent.decode(name: LineTransport.streamEvent, line: Data(line.utf8)))])
        try await waitForCondition("closed item mirrored", timeout: .seconds(5), sourceLocation: #_sourceLocation) { services.daemon.store.closedItems.contains { $0.id == "closed_new" } }
        try await waitForCondition("undo toast", timeout: .seconds(5), sourceLocation: #_sourceLocation) { !toasts.toasts(in: window).isEmpty }
        #expect(toasts.toasts(in: window).first?.action?.isUndo == true)
    }
}
