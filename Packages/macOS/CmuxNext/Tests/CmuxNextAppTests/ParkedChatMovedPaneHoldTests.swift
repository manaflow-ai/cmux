import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// FRAME OWNER REFACTOR S7b with `motion.frameOwner.parkedPages` on (Codex review of 8acc5dc1363): a chat parked in one
/// pane and shown in another of another size (its tab moved) must take the size it shows at before the destination asks
/// whether its paint holds. `AgentPageRedraw.awaits` compares the size the page last drew at with its frame; at its old
/// frame the answer is no, the pane shows the page at once, and the page shows its last frame, drawn at the old size,
/// until it lays out again. With the size first, the pane keeps what it showed until the page drew at the new size.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .closesItsWindows)
struct ParkedChatMovedPaneHoldTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A terminal or browser: shown under the strip.
    final class Other: NSView, PaneParkableContent {}

    private static func pane(in window: NSWindow) -> PaneContentView {
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A"), TabItem(id: TabID("b"), title: "B")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        window.orderFrontRegardless()
        return pane
    }

    private static func window(_ rect: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func settle(_ view: NSView) {
        for _ in 0..<3 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    @Test func aChatParkedInOnePaneHoldsThePaneItShowsInAtAnotherSize() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(DesignTunables.all)
        TunableStore.shared.set("motion.frameOwner.parkedPages", .bool(true))
        defer { TunableStore.shared.set("motion.frameOwner.parkedPages", nil) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "parked-chat-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body>Agent</body></html>".utf8).write(to: file)
        let chat = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        defer { chat.close() }
        let sourceWindow = Self.window(NSRect(x: 100, y: 100, width: 900, height: 600))
        let targetWindow = Self.window(NSRect(x: 200, y: 150, width: 700, height: 480))
        defer { sourceWindow.close(); targetWindow.close() }
        let source = Self.pane(in: sourceWindow), target = Self.pane(in: targetWindow)

        // Drawn in the source pane, then parked there.
        source.show(chat)
        Self.settle(source)
        chat.model.hasPainted = true
        source.show(Other())
        Self.settle(source)
        target.show(Other())
        Self.settle(target)
        try #require(chat.isHidden && chat.superview === source.contentHost, "SETUP: the chat is not parked in the source pane")
        let shows = (target.parkedFrame(of: chat) ?? target.contentHost.bounds).size
        try #require(chat.frame.size != shows, "SETUP: the chat would show at the size it was parked at (\(shows))")

        // Its tab moves to the target pane and shows there.
        target.show(chat)
        #expect(target.paintHold.kept != nil, "the target pane showed the chat at once: it was drawn at \(chat.frame.size) and shows at \(shows)")
        target.endPaintHold()
    }
}
