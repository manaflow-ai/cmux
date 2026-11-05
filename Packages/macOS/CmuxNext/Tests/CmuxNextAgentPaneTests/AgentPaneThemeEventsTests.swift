#if DEBUG
import AppKit
import CmuxNextDesign
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// TERMINAL CREATE COST (2026-11-05, Cmd-T Time Profiler on cmux19, build 2b935052): each Cmd-T built the New Tab
/// chat's theme event twice in the key's turn, once in the adoption's `show` and once in the move's
/// `viewDidMoveToWindow`, 2.4 ms per press (`WebTheme.payloadJSON`, a JSON parse and `JSONValue(foundation:)`),
/// only to find it equal to the event the page already had. A push with the same theme builds no event; a
/// theme that changed still reaches the page.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneThemeEventsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A chat on the page host (its theme goes to the page as an event), 800 x 600.
    private func pageHostChat() throws -> AgentPaneView {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file), pageHost: true,
                                              testRoot: true, chromium: FakeChromiumHosting()))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return view
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        return window
    }

    @Test func aChatAdoptedInTheSameWindowWithTheSameThemeBuildsNoThemeEvent() throws {
        let view = try pageHostChat()
        let window = window()
        defer { window.close() }
        let parking = NSView(frame: NSRect(x: -100_000, y: -100_000, width: 800, height: 600))
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView?.addSubview(parking)
        window.contentView?.addSubview(pane)
        parking.addSubview(view)
        view.applyTheme(force: true)
        let built = view.themeEvents.builds
        try #require(built >= 1, "the chat did not push its theme as a page-host event")
        try #require(view.deliveredThemeEvent != nil)

        // Cmd-T's adoption: the parked chat moves into the pane (its move pushes the theme), then shows the page (again).
        pane.addSubview(view)
        view.applyTheme()

        #expect(view.themeEvents.builds == built,
                "an adoption with the same theme built \(view.themeEvents.builds - built) theme events in the key's turn")
    }

    @Test func aChatWhoseThemeChangedStillPushesTheNewTheme() throws {
        let view = try pageHostChat()
        let window = window()
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.applyTheme(force: true)
        let first = try #require(view.deliveredThemeEvent)

        // A workspace with a picture: the chat's page background changes (AgentPaneScopeGlassTests).
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scope = ThemeScope(level: .room)
        scope.root(workspace)
        scope.setBackdropSelection(try #require(BackdropSelection(id: "van-gogh-starry-night")))
        window.contentView?.addSubview(workspace)
        workspace.addSubview(view)
        view.applyTheme()

        let delivered = try #require(view.deliveredThemeEvent)
        #expect(delivered != first, "the chat kept the theme it had before its scope's picture")
        #expect(delivered == view.performWithTheme { AgentPageEvent.theme(view.themeTokens, surface: view.surfaceKind) })
    }
}
#endif
