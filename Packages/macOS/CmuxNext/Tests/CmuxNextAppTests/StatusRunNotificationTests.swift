import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// A finished `cmux status run` notifies (plans/cmux-next/status-indicators.md section 2):
/// when it took at least `status.runNotifyMinimumSeconds` and its terminal is not visible,
/// unless `status.runNotifyWhenVisible` is on. The CLI writes the run's `run:<pid>` entry busy,
/// then success or error with its exit code and duration; this client notifies only for a run
/// it saw running.
@MainActor
struct StatusRunNotificationTests {
    static let visible = TerminalVisibility(tabSelected: true, paneOnScreen: true, windowShown: true, appActive: true)

    /// One workspace (`ws_1`) whose only tab is terminal `term_7` on surface 1.
    static func store(entries: String = "[]") throws -> DaemonStore {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "w1"), resourceID: ResourceID(rawValue: "ws_1"), name: "w", screens: [screen]),
        ]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"workspaces":[{"id":"ws_1"}],"terminals":[{"id":"term_7"}],"#
            + #""extra":{"state":{"workspace_status":[{"workspace_id":"ws_1","entries":"# + entries + "}]}}}}}"
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        return store
    }

    /// The `run:42` entry the CLI writes, as a `workspace_status` entry.
    static func run(state: String, exitCode: Int? = nil, durationMs: Int? = nil, updated: Int) -> String {
        var fields = #""key":"run:42","text":"Tests","state":"\#(state)","target_terminal":"term_7","updated_at_ms":"\#(updated)""#
        if let exitCode { fields += #","exit_code":\#(exitCode)"# }
        if let durationMs { fields += #","duration_ms":"\#(durationMs)""# }
        return "{\(fields)}"
    }

    static func upsert(_ entries: String, in store: DaemonStore) throws {
        let line = #"{"type":"stream_item","item":{"kind":"delta","changes":[{"kind":"state_upsert","resource":"workspace_status","id":"ws_1","value":{"workspace_id":"ws_1","entries":"#
            + entries + "}}]}}"
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
    }

    static func behavior(minimum: Double = 10, whenVisible: Bool = false) -> StatusBehaviorSettings {
        var behavior = StatusBehaviorSettings()
        behavior.runNotifyMinimumSeconds = minimum
        behavior.runNotifyWhenVisible = whenVisible
        return behavior
    }

    /// Runs one busy pass and one finished pass; returns the notices of the finished pass.
    static func finish(state: String = "success", exitCode: Int = 0, durationMs: Int,
                       behavior: StatusBehaviorSettings, visibility: TerminalVisibility = .hidden) throws -> [StatusRunNotice] {
        let store = try Self.store(entries: "[\(Self.run(state: "busy", updated: 1))]")
        let service = NotificationCenterService()
        var tracker = FinishedStatusRunTracker()
        let busy = service.statusRunNotices(in: store, tracker: &tracker, behavior: behavior, visibility: { _ in visibility })
        #expect(busy.isEmpty, "a running command notified")
        try Self.upsert("[\(Self.run(state: state, exitCode: exitCode, durationMs: durationMs, updated: 2))]", in: store)
        return service.statusRunNotices(in: store, tracker: &tracker, behavior: behavior, visibility: { _ in visibility })
    }

    @Test func aLongRunInAHiddenTerminalNotifiesOnItsTab() throws {
        let notices = try Self.finish(durationMs: 12_000, behavior: Self.behavior())
        let notice = try #require(notices.first)
        #expect(notices.count == 1)
        #expect(notice.title == "Tests is done")
        #expect(notice.level == .info)
        #expect(notice.surface == SurfaceID(rawValue: 1), "the banner opens the run's terminal")
    }

    @Test func aFailedRunNotifiesAsAnErrorWithItsExitCode() throws {
        let notice = try #require(try Self.finish(state: "error", exitCode: 2, durationMs: 15_000, behavior: Self.behavior()).first)
        #expect(notice.title == "Tests failed")
        #expect(notice.level == .error)
        #expect(notice.body.contains("2"), "the body names the exit code: \(notice.body)")
    }

    @Test func aRunShorterThanTheMinimumDoesNotNotify() throws {
        #expect(try Self.finish(durationMs: 9_000, behavior: Self.behavior()).isEmpty)
        #expect(try Self.finish(durationMs: 9_000, behavior: Self.behavior(minimum: 5)).count == 1, "the minimum is the setting's")
    }

    @Test func aVisibleTerminalNotifiesOnlyWhenTheSettingSaysSo() throws {
        #expect(try Self.finish(durationMs: 60_000, behavior: Self.behavior(), visibility: Self.visible).isEmpty)
        #expect(try Self.finish(durationMs: 60_000, behavior: Self.behavior(whenVisible: true), visibility: Self.visible).count == 1)
    }

    /// A finished entry this client never saw running (a relaunch while its badge shows) is old news.
    @Test func aRunThatWasNeverSeenRunningDoesNotNotify() throws {
        let store = try Self.store(entries: "[\(Self.run(state: "success", exitCode: 0, durationMs: 60_000, updated: 2))]")
        var tracker = FinishedStatusRunTracker()
        let notices = NotificationCenterService().statusRunNotices(in: store, tracker: &tracker, behavior: Self.behavior(),
                                                                   visibility: { _ in .hidden })
        #expect(notices.isEmpty)
    }

    /// The same finished entry in a later pass (another status change in the workspace) notifies once.
    @Test func aFinishedRunNotifiesOnce() throws {
        let store = try Self.store(entries: "[\(Self.run(state: "busy", updated: 1))]")
        let service = NotificationCenterService()
        var tracker = FinishedStatusRunTracker()
        let behavior = Self.behavior()
        _ = service.statusRunNotices(in: store, tracker: &tracker, behavior: behavior, visibility: { _ in .hidden })
        let finished = Self.run(state: "success", exitCode: 0, durationMs: 30_000, updated: 2)
        try Self.upsert("[\(finished)]", in: store)
        #expect(service.statusRunNotices(in: store, tracker: &tracker, behavior: behavior, visibility: { _ in .hidden }).count == 1)
        try Self.upsert(#"[\#(finished),{"key":"lint","text":"Lint ok"}]"#, in: store)
        #expect(service.statusRunNotices(in: store, tracker: &tracker, behavior: behavior, visibility: { _ in .hidden }).isEmpty)
    }
}
