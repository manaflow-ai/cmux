import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// nxdog82 preflight: the minimized All chats title drew as "All ch..." (its frame was the text's
/// width without the field's insets), and a computer-use click on the header did nothing (the
/// header was not an accessibility element, so its press was unreachable).
@MainActor @Suite(.serialized) struct SidebarAllChatsHeaderTests {
    private func chats(width: CGFloat) -> SidebarChatsView {
        let view = SidebarChatsView(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.sidebarRowHeight),
                                    defaults: UserDefaults(suiteName: "chats-header-\(UUID())")!)
        view.update([SidebarChatsView.Row(id: "codex:a", title: "A", harness: "codex", brand: nil, folder: "/p/a"),
                     SidebarChatsView.Row(id: "codex:b", title: "B", harness: "codex", brand: nil, folder: "/p/b")],
                    enabled: true, ready: true)
        view.layoutSubtreeIfNeeded()
        view.layout()
        return view
    }

    /// The whole title draws (its cell fits its frame) at the narrowest sidebar, minimized or open.
    @Test(arguments: [CGFloat(160), 200, 260])
    func theTitleIsNeverClipped(width: CGFloat) throws {
        let view = chats(width: width)
        let cell = try #require(view.titleLabel.cell)
        #expect(view.titleLabel.frame.width >= cell.cellSize.width, "minimized at \(width): \(view.titleLabel.frame.width)")
        view.toggleExpanded()
        view.layout()
        #expect(view.titleLabel.frame.width >= cell.cellSize.width, "open at \(width)")
    }

    /// The header is one accessibility button; pressing it opens and closes the section.
    @Test func theHeaderIsAnAccessibleButtonThatOpensTheSection() {
        let view = chats(width: 200)
        #expect(view.header.isAccessibilityElement())
        #expect(view.header.accessibilityRole() == .button)
        #expect(view.header.accessibilityLabel() == SidebarChatsView.title)
        #expect(!view.isExpanded)
        #expect(view.header.accessibilityPerformPress())
        #expect(view.isExpanded)
    }

    /// nxdog84: a real mouse click on the header did nothing while AX press worked: in a window
    /// that is not key the first click only activated it (the header took no first mouse).
    @Test func aRealMouseClickOnTheHeaderOpensTheSection() throws {
        let view = chats(width: 220)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 220, height: Metrics.sidebarRowHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.frame = window.contentView?.bounds ?? view.frame
        view.layoutSubtreeIfNeeded()
        view.layout()
        #expect(view.header.acceptsFirstMouse(for: nil), "the first click in an inactive window opens it")
        let center = view.header.convert(NSPoint(x: view.titleLabel.frame.midX, y: view.titleLabel.frame.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        #expect(view.isExpanded, "one real click opens All chats")
    }
}
