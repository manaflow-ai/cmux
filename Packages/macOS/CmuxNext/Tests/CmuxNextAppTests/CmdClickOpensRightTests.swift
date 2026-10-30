import AppKit
import CmuxNextBridge
import CmuxNextBrowser
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// User 2026-10-20: "cmd click on links needs to always open in the right". Every link click goes
/// through ``LinkOpener`` from the pane that shows the clicked view (a Home or agent chat, a cmux
/// page), never from whichever pane has focus: with focus in the right pane, a Home chat's link
/// split that pane again instead of reusing it. A browser page's Command-click maps to the same
/// opener by default (`browser.links.cmdClick`: `linkPlacement`).
@MainActor struct CmdClickOpensRightTests {
    /// Two panes on two screens: the chat's and the focused one.
    private static func tree() -> DaemonTree {
        let screens = (1...2).map { n in
            ScreenSnapshot(id: ScreenID(rawValue: UInt64(n)), layout: .leaf(PaneID(rawValue: UInt64(n))),
                           panes: [PaneSnapshot(id: PaneID(rawValue: UInt64(n)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(n)), title: "t\(n)")])])
        }
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: screens)])
    }

    private static func panes() throws -> (AppServices, PaneController, PaneController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.daemon.store.apply(snapshot: tree())
        let screens = try #require(services.daemon.store.workspaces.first?.screens)
        let models = screens.flatMap { $0.panes }
        try #require(models.count == 2)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let made = models.map { PaneController(pane: $0, daemon: services.daemon, layoutPaneID: LayoutPaneID($0.id), services: services, state: state) }
        return (services, made[0], made[1])
    }

    /// The pane a click came from is the one whose view holds the clicked view (the chat in the
    /// left pane), not the focused pane on the right.
    @Test func theSourceIsThePaneHoldingTheClickedView() throws {
        let (services, chat, focused) = try Self.panes()
        defer { chat.teardown(); focused.teardown() }
        let transcript = NSView()
        chat.view.addSubview(transcript)
        #expect(services.linkOpener.source(containing: transcript, in: [focused, chat]) === chat)
        #expect(services.linkOpener.source(containing: NSView(), in: [focused, chat]) == nil)
    }

    /// Leo 2026-10-21: a Cmd-clicked link with no pane on the right showed in the clicked pane first, then
    /// moved into the new split (two animations). The tab that the split takes is asked of the daemon
    /// unselected, so the clicked pane keeps showing its own tab and only the split animates.
    @Test func aLinkBoundForANewSplitNeverTakesTheClickedPane() async throws {
        let (services, source, other) = try Self.panes()
        defer { source.teardown(); other.teardown() }
        let browserTabs = services.cache.browserTabs
        browserTabs.serves = { _ in true }
        browserTabs.cefUnavailable = { nil }
        services.linkOpener.placement = { .splitRight }
        let link = try #require(URL(string: "https://example.com/"))
        let activated = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            browserTabs.create = { _, _, _, _, _, activate, _ in
                done.resume(returning: activate)
                throw CancellationError()
            }
            // A refused open never asks the daemon: fail here rather than wait forever.
            if !services.linkOpener.openWeb(link, from: source, background: false) {
                Issue.record("the Cmd-click opened nothing")
                done.resume(returning: true)
            }
        }
        #expect(!activated, "the split's tab was made the clicked pane's selected tab before it moved")
    }

    /// cmux's own default: Command-click in a browser page goes to the pane on the right.
    @Test func theAppsBrowserMappingSendsCommandClickRight() {
        let mapping = BrowserLinkClickMapping(BrowserLinkClickSetting.fallback)
        #expect(mapping.cmdClick.rawValue == "linkPlacement")
    }
}
