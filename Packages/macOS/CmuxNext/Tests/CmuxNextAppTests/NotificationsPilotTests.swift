import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// The scheduler pilot in the notifications (plans/cmux-next/chrome-parity/p06-scheduler.md, task
/// 205), on the objects the app runs: the panel's ledger watch (what `NotificationsPanelController`
/// opens and closes) reads nothing while the panel is closed and loads once when it opens; the
/// service's arrivals (`follow(_:)` on a daemon) run one pass on the next frame however many came,
/// never in the arrivals' own turn; a held OSC 7501 alert is delivered once, by its record or by its
/// deadline on the scheduler's clock; a `timeout` dismissal fires on that clock.
@MainActor
struct NotificationsPilotTests {
    /// One workspace whose only tab is on surface 1 (terminal `term_7`).
    private static func seed(_ store: DaemonStore) {
        _ = NSApplication.shared
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
    }

    private static func arrive(_ id: UInt64, in store: DaemonStore) throws {
        let wire = #"{"notification":\#(id),"title":"Done","body":"","level":"info","surface":1,"source":"agent"}"#
        store.apply(.notification(try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))))
    }

    private static func located(in store: DaemonStore) throws -> LocatedTab {
        let workspace = try #require(store.workspaces.first)
        let pane = try #require(workspace.screens.first?.panes.first)
        return LocatedTab(tab: try #require(pane.tabs.first), pane: pane, workspace: workspace)
    }

    /// Terminal `term_7`'s OSC 7501 records, as the session stream carries them.
    private static func records(_ json: String, in store: DaemonStore) throws {
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_7","extra":{"program_status":\#(json)}}],"extra":{"state":{}}}}}"#
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
    }

    // MARK: The panel

    /// The controller's sequence: `show()` opens the watch (which loads through the controller's
    /// `reload()`, which notes the load), `close(restoringKey:)` closes it.
    @Test func aClosedPanelReadsNothingAndLoadsOnceWhenItOpens() throws {
        let frames = NotificationFrames()
        let store = DaemonStore()
        Self.seed(store)
        let ledger = NotificationsPanelLedgerWatch(node: VisibilityNode(root: "notifications.panel", own: .hidden), store: store,
                                                   work: frames.work)
        ledger.onChange = { [weak ledger] in ledger?.noteLoaded() }
        ledger.open()
        #expect(ledger.loads == 1, "the open loads once")
        ledger.close()
        let reads = ledger.reads
        for id in 1...100 { try Self.arrive(UInt64(id), in: store) }
        frames.frame()
        frames.frame()
        #expect(ledger.reads == reads, "a closed panel read the ledger \(ledger.reads - reads) times")
        #expect(ledger.loads == 1, "a closed panel loaded")
        ledger.open()
        #expect(ledger.loads == 2, "the panel loads once when it opens")
        // Open, 50 arrivals in one turn are one load on the next frame. (Each arrival still
        // re-arms the tracking with one read in its own turn: the observation's cost per change.)
        for id in 101...150 { try Self.arrive(UInt64(id), in: store) }
        #expect(ledger.loads == 2, "nothing loads in the arrivals' own turn")
        frames.frame()
        #expect(ledger.loads == 3, "fifty arrivals loaded \(ledger.loads - 2) times")
        ledger.close()
    }

    // MARK: Arrivals

    @Test func fiftyArrivalsInOneTurnRunOneArrivalPassOnTheNextFrame() throws {
        let frames = NotificationFrames()
        let daemon = DaemonService(mainWork: frames.work)
        Self.seed(daemon.store)
        let service = frames.service()
        service.follow(daemon)
        frames.frame()
        #expect(service.arrivalPasses == 0)
        for id in 1...50 { try Self.arrive(UInt64(id), in: daemon.store) }
        #expect(service.arrivalPasses == 0, "an arrival pass ran in the arrivals' own turn")
        frames.frame()
        #expect(service.arrivalPasses == 1, "fifty arrivals in one turn ran \(service.arrivalPasses) passes")
        #expect(service.lastSeen == 50)
        frames.frame()
        #expect(service.arrivalPasses == 1)
    }

    // MARK: Held OSC 7501 alerts

    static let approval = #"{"notification":5,"title":"terraform apply needs approval","body":"Apply 3 changes?","level":"warning","surface":1,"source":"terminal"}"#
    static let approvalRecord = #"[{"id":"","state":"blocked","kind":"permission","app":"terraform","title":"terraform apply","msg":"Apply 3 changes?","updated_seq":"2"}]"#

    @Test func aHeldAlertIsDeliveredOnceWithTheRecordThatArrives() throws {
        let frames = NotificationFrames()
        let store = DaemonStore()
        Self.seed(store)
        try Self.records("[]", in: store)
        let service = frames.service()
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(Self.approval.utf8))
        var delivered: [ProgramStatusNotification?] = []
        service.holdUntilRecord(notification, located: try Self.located(in: store)) { delivered.append($0) }
        #expect(delivered.isEmpty && service.heldProgramAlerts.count == 1, "no record yet: held")
        try Self.records(Self.approvalRecord, in: store)
        frames.frame()
        #expect(delivered.count == 1)
        #expect(delivered.first??.record.app == "terraform", "delivered with its record")
        #expect(service.heldProgramAlerts.isEmpty)
        // Its deadline was cancelled: nothing more when it would have come.
        frames.advance(by: NotificationCenterService.programAlertWait + .milliseconds(300))
        #expect(delivered.count == 1)
    }

    @Test func aHeldAlertWithNoRecordIsDeliveredAtItsDeadline() throws {
        let frames = NotificationFrames()
        let store = DaemonStore()
        Self.seed(store)
        try Self.records("[]", in: store)
        let service = frames.service()
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(Self.approval.utf8))
        var delivered: [ProgramStatusNotification?] = []
        service.holdUntilRecord(notification, located: try Self.located(in: store)) { delivered.append($0) }
        frames.advance(by: NotificationCenterService.programAlertWait - .milliseconds(100))
        #expect(delivered.isEmpty, "delivered before its deadline")
        frames.advance(by: .milliseconds(300))
        #expect(delivered.count == 1)
        #expect(delivered.first.map { $0 == nil } == true, "delivered without a record")
        #expect(service.heldProgramAlerts.isEmpty)
        // A record that comes later delivers nothing more.
        try Self.records(Self.approvalRecord, in: store)
        frames.frame()
        #expect(delivered.count == 1)
    }

    // MARK: Timeout dismissals

    @Test func aTimeoutDismissalFiresOnTheSchedulersClock() throws {
        let frames = NotificationFrames()
        let store = DaemonStore()
        Self.seed(store)
        let service = frames.service()
        service.desktopPostingEnabled = false
        let located = try Self.located(in: store)
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(
            #"{"notification":3,"title":"Done","body":"","level":"info","surface":1,"source":"agent"}"#.utf8))
        var decision = NotificationPolicy.Decision()
        decision.timeout = 2
        service.deliver(notification, source: .agent, located: located, decision: decision, program: nil)
        #expect(service.timeouts[located.tab.id] != nil, "the dismissal has its deadline")
        frames.advance(by: .milliseconds(1_900))
        #expect(service.timeouts[located.tab.id] != nil, "the dismissal fired early")
        frames.advance(by: .milliseconds(400))
        #expect(service.timeouts[located.tab.id] == nil, "the dismissal did not fire on the scheduler's clock")
    }
}
