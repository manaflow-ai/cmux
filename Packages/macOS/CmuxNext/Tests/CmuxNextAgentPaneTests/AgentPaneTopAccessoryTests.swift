import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The New Tab page shows the omnibar on top (cx-e2aa, Lawrence 2026-10-09: "we should show the
/// omnibar in new tab page"). The pane holds the App's bar over the page while it is a New Tab page
/// and gives the page the whole pane once it becomes a chat; the bar never covers the page.
@MainActor
@Suite struct AgentPaneTopAccessoryTests {
    struct SilentHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake {
            try await Task.sleep(for: .seconds(3_600))
            throw CancellationError()
        }
    }

    static func content(of view: AgentPaneView) -> NSView { view.page.map { $0 as NSView } ?? view.webView }

    @Test func aNewTabPageShowsTheBarOnTopAndThePageBelowIt() throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: SilentHost(), newTab: AgentPaneNewTab(kind: .agent))))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let bar = NSView()
        view.topBar.set(bar, height: 40)
        view.layoutSubtreeIfNeeded()
        #expect(bar.superview === view)
        #expect(!bar.isHidden)
        let barRect = view.convert(bar.frame, to: nil)
        let pageRect = view.convert(Self.content(of: view).frame, to: nil)
        #expect(barRect.height == 40 && barRect.width == 600)
        #expect(pageRect.height == 360 && pageRect.width == 600)
        // On top: the bar's bottom edge is the page's top edge, in window coordinates.
        #expect(barRect.minY == pageRect.maxY)
    }

    @Test func thePageTakesTheWholePaneOnceItBecomesAChat() async throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: SilentHost(), newTab: AgentPaneNewTab(kind: .agent))))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let bar = NSView()
        view.topBar.set(bar, height: 40)
        view.layoutSubtreeIfNeeded()
        _ = await view.model.respond(to: .persistSession("s1"))
        view.layoutSubtreeIfNeeded()
        #expect(bar.isHidden)
        #expect(Self.content(of: view).frame.size == NSSize(width: 600, height: 400))
    }

    @Test func aPlainChatNeverShowsTheBar() throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: SilentHost())))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let bar = NSView()
        view.topBar.set(bar, height: 40)
        view.layoutSubtreeIfNeeded()
        #expect(bar.isHidden)
        #expect(Self.content(of: view).frame.size == NSSize(width: 600, height: 400))
    }

    @Test func aChatThatBecomesANewTabPageShowsTheBar() throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: SilentHost())))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let bar = NSView()
        view.topBar.set(bar, height: 40)
        view.becomeNewTab(AgentPaneNewTab(kind: .agent))
        view.layoutSubtreeIfNeeded()
        #expect(!bar.isHidden)
        #expect(Self.content(of: view).frame.height == 360)
    }

    /// cx-e2aa: a chat a chip pick started behind a New Tab page, never sent, is discarded when the
    /// page closes (the page's harness switch drops it); a page that became a chat keeps its chat.
    @Test func closingANewTabPageAsksThePageToDiscardItsUnsentChat() async throws {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: SilentHost(), newTab: AgentPaneNewTab(kind: .agent))))
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }
        view.topBar.discardUnsentChat()
        #expect(scripts == ["window.dispatchEvent(new Event('acpmux-newtab-close'))"])
        _ = await view.model.respond(to: .persistSession("s1"))
        scripts.removeAll()
        view.topBar.discardUnsentChat()
        #expect(scripts.isEmpty)
    }

    /// Cmd-L's page (cx-e2aa): the handshake tells the page to leave its field unfocused, so the
    /// omnibar keeps the keyboard; any other page focuses its field (the key absent).
    @Test func aPageOpenedForTheOmnibarTellsThePageNotToFocusItsField() throws {
        var page = AgentPaneNewTab(kind: .agent)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any]
        #expect(plain?["focusesField"] == nil)
        page.focusesField = false
        let omnibar = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any]
        #expect(omnibar?["focusesField"] as? Bool == false)
    }
}
