import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSettings
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Default call (coordinator, 2026-10-14, reversible): a turn that finishes in a pane the user is
/// watching is already seen, so it does not mark the workspace unread. The notification stays in
/// the history and an OSC 7501 done keeps its done state on the row. Approval, question, plan
/// review and error always mark unread, watched or not, and an unwatched pane behaves as before.
/// Showcase captures (`CMUX_NEXT_SHOWCASE`) take the same path, without banners.
/// 2026-10-20 (Austin): that read on sight is the `focus` dismissal's. Under the default `click`
/// a watched finish posts no banner but keeps its ring until the pane is clicked or typed in.
@MainActor
struct WatchedDoneReadTests {
    static let watched = TerminalVisibility(tabSelected: true, paneOnScreen: true, windowShown: true, appActive: true)

    struct Arrival {
        let service: NotificationCenterService
        let store: DaemonStore
        let located: LocatedTab

        var read: Bool { service.log.contains("ack \(located.tab.id)") }
    }

    /// Delivers one daemon notification (`source`, `level`, `title`) to a tab whose OSC 7501
    /// records are `records`, seen as `visibility`.
    static func arrive(source: String, level: String, title: String, records: String = "[]",
                       marker: TabNotification? = nil,
                       visibility: TerminalVisibility, showcase: Bool = false,
                       dismissal: NotificationDismissal = .focus) throws -> Arrival {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7", notification: marker)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_7","extra":{"program_status":\#(records)}}],"extra":{"state":{}}}}}"#
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        let wire = #"{"notification":5,"title":"\#(title)","body":"","level":"\#(level)","surface":1,"source":"\#(source)"}"#
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        store.apply(.notification(notification))
        let workspace = try #require(store.workspaces.first)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let located = LocatedTab(tab: try #require(paneModel.tabs.first), pane: paneModel, workspace: workspace)

        let service = NotificationCenterService()
        service.preferences.dismissal = dismissal
        service.terminalNotificationsEnabled = { true }
        service.desktopPostingEnabled = !showcase
        service.arrive(notification, located: located, visibility: visibility)
        return Arrival(service: service, store: store, located: located)
    }

    @Test func aTurnThatFinishesInAWatchedPaneIsReadButStaysInTheHistory() throws {
        let arrival = try Self.arrive(source: "agent", level: "info", title: "Claude finished", visibility: Self.watched)
        #expect(arrival.read, "the user watched it finish")
        #expect(arrival.store.notifications.map(\.notification.rawValue) == [5], "the history keeps it")
        #expect(arrival.service.desktop.posted.isEmpty)
    }

    @Test func aProgramDoneInAWatchedPaneIsReadAndKeepsItsDoneState() throws {
        let records = #"[{"id":"","state":"done","app":"make","updated_seq":"4"}]"#
        let arrival = try Self.arrive(source: "terminal", level: "info", title: "make is done", records: records, visibility: Self.watched)
        #expect(arrival.read)
        #expect(StatusMapping.shared.outcome(arrival.located.tab) == .success, "the row still shows it done")
    }

    /// The default `click`: seen finishing, so no banner, and the ring stays until the pane is clicked.
    @Test func aWatchedTurnKeepsItsRingWithoutABannerByDefault() throws {
        let arrival = try Self.arrive(source: "agent", level: "info", title: "Claude finished", visibility: Self.watched,
                                      dismissal: NotificationPreferences().dismissal)
        #expect(!arrival.read, "the ring cleared with no click in the pane")
        #expect(arrival.service.desktop.posted.isEmpty, "a watched finish posted a banner")
    }

    @Test func aWatchedProgramDoneKeepsItsRingWithoutABannerByDefault() throws {
        let records = #"[{"id":"","state":"done","app":"make","updated_seq":"4"}]"#
        let arrival = try Self.arrive(source: "terminal", level: "info", title: "make is done", records: records, visibility: Self.watched,
                                      dismissal: NotificationPreferences().dismissal)
        #expect(!arrival.read, "the ring cleared with no click in the pane")
        #expect(arrival.service.desktop.posted.isEmpty, "a watched done posted a banner")
    }

    /// The timeout dismissal keeps a watched finish unread and still clears it at its deadline.
    @Test func aWatchedTurnUnderTheTimeoutModeGetsItsDeadline() throws {
        let arrival = try Self.arrive(source: "agent", level: "info", title: "Claude finished", visibility: Self.watched,
                                      dismissal: .timeout)
        #expect(!arrival.read)
        #expect(arrival.service.log.contains { $0.hasPrefix("timeout \(arrival.located.tab.id) ") }, "no deadline was scheduled")
        #expect(arrival.service.desktop.posted.isEmpty)
    }

    @Test(arguments: [("warning", "Claude needs approval"), ("warning", "Claude asked a question"),
                      ("warning", "Claude requested plan review"), ("error", "Claude reported an error")])
    func anAskOrAnErrorStaysUnreadInAWatchedPane(_ level: String, _ title: String) throws {
        let arrival = try Self.arrive(source: "agent", level: level, title: title, visibility: Self.watched)
        #expect(!arrival.read, "\(title) needs the user even while they watch")
    }

    @Test(arguments: [NotificationLevel.warning, .error])
    func aWatchedTurnLeavesAnEarlierUnreadAskOrErrorUnread(_ level: NotificationLevel) throws {
        let marker = TabNotification(notification: NotificationID(rawValue: 4), unread: true, level: level, source: "agent")
        let arrival = try Self.arrive(source: "agent", level: "info", title: "Claude finished", marker: marker, visibility: Self.watched)
        #expect(!arrival.read, "reading the tab would read the \(level) the user has not seen")
    }

    @Test func aTurnThatFinishesUnwatchedStaysUnread() throws {
        let arrival = try Self.arrive(source: "agent", level: "info", title: "Claude finished", visibility: .hidden)
        #expect(!arrival.read)
    }

    @Test func showcaseReadsAWatchedTurnLikeTheAppWithoutABanner() throws {
        let watched = try Self.arrive(source: "agent", level: "info", title: "Claude finished", visibility: Self.watched, showcase: true)
        #expect(watched.read)
        let unwatched = try Self.arrive(source: "agent", level: "info", title: "Claude finished", visibility: .hidden, showcase: true)
        #expect(!unwatched.read)
        #expect(unwatched.service.desktop.posted.isEmpty, "showcase posts no banners")
    }
}
