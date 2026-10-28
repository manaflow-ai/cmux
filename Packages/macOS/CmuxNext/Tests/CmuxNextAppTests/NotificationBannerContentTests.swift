@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing
import CmuxNextFeed

/// A system banner says where it came from, who and what state, and what was said
/// (plans: ~/fun/cmux-prompts/logs/notifications-DESIGN.md): title = workspace › tab,
/// subtitle = the agent or program state, body = the latest message as clean plain text.
@MainActor
struct NotificationBannerContentTests {
    let format = NotificationBannerFormatter()

    // MARK: Formatter, per event type

    @Test func anAgentFinishedNamesTheWorkspaceAndTabAndSaysWhatTheAgentSaid() {
        let content = format.content(headline: "Claude finished", posterSubtitle: nil,
                                     body: "Fixed the **flaky** login test and pushed `main`.",
                                     workspace: "api-server", tab: "Claude Code", host: nil)
        #expect(content.title == "api-server › Claude Code")
        #expect(content.subtitle == "Claude finished")
        #expect(content.body == "Fixed the flaky login test and pushed main.")
    }

    @Test func aChatNamedLikeTheHeadlineIsNotRepeated() {
        let content = format.content(headline: "Fix login needs input", posterSubtitle: nil, body: "Run the tests?",
                                     workspace: "api", tab: "Fix login", host: nil)
        #expect(content.title == "api › Fix login")
        #expect(content.subtitle == "Needs input")
    }

    @Test func aTabNamedLikeItsWorkspaceShowsTheWorkspaceOnce() {
        let content = format.content(headline: "Codex finished", posterSubtitle: nil, body: "",
                                     workspace: "web", tab: "web", host: nil)
        #expect(content.title == "web")
    }

    @Test func aTerminalProgramWritesOnlyTheSubtitleAndBody() {
        let content = format.content(headline: "Build finished", posterSubtitle: nil, body: "42 targets in 3m",
                                     workspace: "ios", tab: "zsh", host: nil)
        #expect(content.title == "ios › zsh", "the app, not the program, names where it came from")
        #expect(content.subtitle == "Build finished")
        #expect(content.body == "42 targets in 3m")
    }

    @Test func aNotifySubtitleFollowsTheHeadline() {
        let content = format.content(headline: "Deploy", posterSubtitle: "staging", body: "done",
                                     workspace: "infra", tab: "deploy", host: nil)
        #expect(content.subtitle == "Deploy · staging")
    }

    @Test func aRemoteTerminalNamesItsMachine() {
        let content = format.content(headline: "Claude finished", posterSubtitle: nil, body: "",
                                     workspace: "api", tab: "claude", host: "cmux-mini-3")
        #expect(content.title == "api › claude · cmux-mini-3")
    }

    @Test func withoutATabTheHeadlineIsTheTitle() {
        let content = format.content(headline: "Claude finished", posterSubtitle: "x", body: "ok",
                                     workspace: nil, tab: nil, host: nil)
        #expect(content.title == "Claude finished")
        #expect(content.subtitle == "x")
    }

    @Test func markdownBecomesPlainText() {
        let markdown = """
        ## Summary

        - Fixed [the login bug](https://github.com/x/y/pull/1)
        - Added ![a screenshot](shot.png) and *two* tests

        ```swift
        let x = 1
        ```
        > Pushed to __main__.
        """
        let body = format.plainText(markdown)
        #expect(body == "Summary\n• Fixed the login bug\n• Added a screenshot and two tests\nlet x = 1\nPushed to main.")
    }

    @Test func snakeCaseAndArithmeticKeepTheirCharacters() {
        #expect(format.plainText("set max_retries to 2*3*4") == "set max_retries to 2*3*4")
    }

    @Test func aLongMessageIsCutOnAWord() {
        let long = Array(repeating: "word", count: 100).joined(separator: " ")
        let body = format.plainText(long)
        #expect(body.count <= 241)
        #expect(body.hasSuffix("word…"))
    }

    @Test func aLongNameIsCut() {
        let content = format.content(headline: "", posterSubtitle: nil, body: "",
                                     workspace: String(repeating: "w", count: 60), tab: nil, host: nil)
        #expect(content.title == String(repeating: "w", count: 39) + "…")
        #expect(content.subtitle == nil)
    }

    // MARK: Through the service

    /// The banner the service posts for `wire` on tab "Claude Code" (with an unread marker) in
    /// workspace "api-server", and the service.
    func deliver(_ wire: String, tabName: String = "Claude Code",
                 configure: (NotificationCenterService) -> Void = { _ in }) throws -> (DesktopNotifier.Posted?, NotificationCenterService, DaemonStore) {
        let store = DaemonStore()
        let marker = TabNotification(notification: NotificationID(rawValue: 5), unread: true, source: "agent")
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7", name: tabName, notification: marker)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "api-server", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let located = LocatedTab(tab: try #require(paneModel.tabs.first), pane: paneModel, workspace: workspace)
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        let service = NotificationCenterService()
        service.screenLocked = { false }
        service.terminalNotificationsEnabled = { true }
        configure(service)
        var decision = NotificationPolicy.Decision()
        decision.desktop = true
        let source = NotificationSource(rawValue: notification.source ?? "") ?? .agent
        service.deliver(notification, source: source, located: located, decision: decision, program: nil)
        return (service.desktop.posted.last, service, store)
    }

    static let finished = #"{"notification":5,"title":"Claude finished","body":"","preview":"Fixed the **flaky** login test.","level":"info","surface":1,"source":"agent"}"#

    @Test func anAgentBannerSaysWhereWhoAndWhat() throws {
        let posted = try #require(try deliver(Self.finished).0)
        #expect(posted.title == "api-server › Claude Code")
        #expect(posted.subtitle == "Claude finished")
        #expect(posted.body == "Fixed the flaky login test.")
    }

    @Test func aTerminalBannerCannotPoseAsAnotherTerminal() throws {
        let wire = #"{"notification":5,"title":"api-server › other","body":"hi","level":"info","surface":1,"source":"terminal"}"#
        let posted = try #require(try deliver(wire, tabName: "zsh").0)
        #expect(posted.title == "api-server › zsh")
        #expect(posted.subtitle == "api-server › other")
    }

    @Test func everyBannerOffersOpenAndMarkAsRead() throws {
        let posted = try #require(try deliver(Self.finished).0)
        #expect(posted.category == DesktopNotifier.defaultCategory)
    }

    @Test func markAsReadReadsTheBannersTabWithoutOpeningIt() throws {
        let (posted, service, store) = try deliver(Self.finished)
        let banner = try #require(posted)
        let tab = try #require(service.locate(surface: SurfaceID(rawValue: 1), in: store)?.tab)
        #expect(tab.hasUnread)
        service.markRead(banner: banner.id, surface: SurfaceID(rawValue: 1), in: store)
        #expect(!tab.hasUnread)
    }

    // MARK: Show Previews setting

    @Test func showPreviewsLoadsFromCmuxJSON() {
        let root: CmuxNextSettings.JSONValue = .object(["notifications": .object(["showPreviews": .string("never")])])
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).notifications.showPreviews == .never)
        #expect(NotificationPreferences().showPreviews == .whenUnlocked)
        let bad: CmuxNextSettings.JSONValue = .object(["notifications": .object(["showPreviews": .string("sometimes")])])
        #expect(CmuxConfigSnapshot.parse(bad, validDensities: [], validMetrics: []).diagnostics.contains { $0.path == "notifications.showPreviews" })
    }

    @Test func showPreviewsNeverHidesTheMessage() throws {
        let posted = try #require(try deliver(Self.finished) { service in
            var prefs = NotificationPreferences()
            prefs.showPreviews = .never
            service.preferences = prefs
        }.0)
        #expect(posted.body == "")
    }
}
