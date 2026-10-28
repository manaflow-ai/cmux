import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import Foundation
import Testing

/// Chat tools and their menus share the chat's glass. The layout's decorative pane frame lives
/// above page windows, so framing the chat also draws that line across page menus.
@MainActor @Suite(.serialized) struct AgentPaneFramelessChromeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class GatedPage: NSView, PaneFirstPaintGated {
        var awaitsFirstPaint = true
        var painted: (() -> Void)?
        func whenFirstPainted(_ body: @escaping () -> Void) { painted = body }
        func paint() { awaitsFirstPaint = false; painted?(); painted = nil }
    }

    @Test(arguments: [false, true], [false, true])
    func chatHasNoSeparatePaneFrame(hidesStrip: Bool, wholeCard: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "frameless-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>Chat</body></html>".utf8).write(to: file)
        let page = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        defer { page.close() }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("chat"), title: "Chat")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.hidesStrip = hidesStrip
        pane.show(page)
        let host = PaneHostView(pane: PaneID("chat"), content: pane)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        host.applyShape(padding: 4, cornerRadius: 12, wholeCard: wholeCard)
        pane.layoutSubtreeIfNeeded()
        updateChrome(host)
        #expect(!host.chrome.showsBorder, "a decorative pane border outlines the chat tools")
        #expect(!host.chrome.showsRing, "the focus frame draws above the chat tools and page menus")
        #expect(pane.contentHost.layer?.cornerRadius == 0, "the chat has a second rounded panel edge")
        #expect(pane.superview?.layer?.cornerRadius == (wholeCard ? 12 : 0), "the floating card lost its outer silhouette")

        // Reusing the pane for a terminal or browser restores its configured frame.
        pane.show(NSView())
        pane.layoutSubtreeIfNeeded()
        updateChrome(host)
        #expect(host.chrome.showsRing, "a regular pane lost its configured focus frame after a chat")
    }

    private func updateChrome(_ host: PaneHostView) {
        var ring = FocusRingSettings()
        ring.enabled = true
        host.setChrome(showsRing: true, dim: 0, focusRing: ring,
                       border: PaneOverlayView.Border(shows: true), attention: nil,
                       attentionSettings: AttentionSettings(), focused: true, animated: false)
    }

    @Test(arguments: [false, true])
    func anOutgoingPaneKeepsItsFrameUntilTheChatPaints(hidesStrip: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-frame-hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>Chat</body></html>".utf8).write(to: file)
        let page = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        defer { page.close() }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("chat"), title: "Chat")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.hidesStrip = hidesStrip
        let outgoing = NSView()
        pane.show(outgoing)
        let host = PaneHostView(pane: PaneID("chat"), content: pane)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        host.applyShape(padding: 4, cornerRadius: 12)
        pane.layoutSubtreeIfNeeded()
        updateChrome(host)
        let outgoingHeader = pane.paneHeaderHeight
        pane.show(page)
        try #require(pane.paintHold.kept === outgoing)
        #expect(host.chrome.showsRing, "the visible outgoing pane lost its focus frame before the chat painted")
        #expect(pane.contentHost.layer?.cornerRadius == 12, "the outgoing pane's clip changed before the swap")
        #expect(pane.paneHeaderHeight == outgoingHeader, "the visible outgoing pane's frame moved before the chat painted")

        page.model.markPainted()
        #expect(pane.paintHold.kept == nil)
        #expect(!host.chrome.showsRing, "the chat kept the outgoing pane's frame after painting")
        #expect(pane.contentHost.layer?.cornerRadius == 0, "the chat kept the outgoing pane's rounded clip")

        let next = GatedPage()
        pane.show(next)
        try #require(pane.paintHold.kept === page)
        #expect(!host.chrome.showsRing, "the visible chat gained the next page's frame before it painted")
        next.paint()
        #expect(host.chrome.showsRing, "the next page did not restore its configured frame after painting")
    }
}
