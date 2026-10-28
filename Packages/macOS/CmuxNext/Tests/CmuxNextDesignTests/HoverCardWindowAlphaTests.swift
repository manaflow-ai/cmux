import AppKit
@testable import CmuxNextDesign
import Testing

/// A hover card's fades run on its content layer's opacity, on the
/// render server. The window's `alphaValue` is never written: an `animator().alphaValue` fade set
/// the window's alpha in the window server once per frame from the main thread (and a glass card
/// ignores window alpha).
@MainActor @Suite(.serialized) struct HoverCardWindowAlphaTests {
    /// A card window that counts every write of its alpha, the animator's per-frame steps included.
    final class AlphaCountingPanel: NSPanel {
        var alphaWrites = 0
        override var alphaValue: CGFloat {
            get { super.alphaValue }
            set {
                alphaWrites += 1
                super.alphaValue = newValue
            }
        }
    }

    /// Set when a hide's completion runs.
    @MainActor final class Landed {
        var value = false
    }

    private static func panel() -> AlphaCountingPanel {
        _ = NSApplication.shared
        let panel = AlphaCountingPanel(contentRect: NSRect(x: 200, y: 200, width: 300, height: 160),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.adoptPopupStyle(card: NSView())
        panel.alphaWrites = 0
        return panel
    }

    /// Runs the main run loop until `done` or 2 s (a fade lands on the run loop where it animates).
    private static func runUntil(_ done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 2)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @Test func enterResumeAndExitFadeTheContentLayerAndNeverTheWindowAlpha() throws {
        let panel = Self.panel()
        defer { panel.orderOut(nil) }
        let layer = try #require(panel.contentView?.layer, "the card's content is layer-backed")

        HoverCardMotion.standard.enter(panel, placement: .below)
        #expect(panel.isVisible)
        #expect(layer.opacity == 1, "the card rests at full opacity (the model value)")
        if let fade = layer.animation(forKey: "opacity") as? CABasicAnimation {
            #expect((fade.fromValue as? NSNumber)?.floatValue == 0, "a first show fades in from clear")
        }

        let exited = Landed()
        HoverCardMotion.standard.exit(panel) { exited.value = true }
        #expect(layer.opacity == 0, "a hide fades the layer to clear")
        #expect(HoverCardMotion.isFaded(panel))
        HoverCardMotion.standard.resume(panel)
        #expect(layer.opacity == 1, "a return fades the layer back in")
        #expect(!HoverCardMotion.isFaded(panel))
        Self.runUntil { exited.value }
        #expect(exited.value, "the taken-over hide never ran its completion")

        #expect(panel.alphaWrites == 0, "the fades wrote the window's alpha \(panel.alphaWrites) times")
        #expect(panel.alphaValue == 1)
    }

    /// The hover card panel itself: a show, a hide and a return leave its window alpha at 1.
    @Test func theHoverCardPanelKeepsItsWindowAlphaAtOne() throws {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let panel = HoverCardPanel()
        defer {
            panel.orderOut(nil)
            parent.close()
        }
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.widthAnchor.constraint(equalToConstant: 240), body.heightAnchor.constraint(equalToConstant: 90)])
        let anchor = CGRect(x: parent.frame.minX, y: parent.frame.maxY - 60, width: 200, height: 40)
        func show() {
            panel.present(body: body, anchor: anchor, placement: .beside, parent: parent, themeAnchor: nil, sliding: false, applyTheme: {})
        }
        show()
        #expect(panel.alphaValue == 1)
        panel.dismiss()
        #expect(panel.alphaValue == 1, "the hide faded the window, not the card")
        show()
        #expect(panel.isShowingCard)
        #expect(!HoverCardMotion.isFaded(panel), "a return during the fade-out did not fade back in")
        #expect(panel.alphaValue == 1)
    }
}
