import AppKit
import CmuxNextDesign
@testable import CmuxNextHome
import Foundation
import Testing

/// Chat Colors… is AppKit (plans/cmux-next/no-swiftui-DESIGN.md): the panel builds no
/// `NSHostingView`, its swatches store a colour on a press and show the stored one as selected,
/// a change from elsewhere (`cmux chat colors`) shows at once, and Reset clears the chat.
@MainActor @Suite(.serialized) struct HomeChatColorsPanelTests {
    private struct Rig {
        let store: HomeChatColorStore
        let panel: HomeChatColorsPanel
        let window: NSPanel
    }

    private func rig() throws -> Rig {
        let defaults = try #require(UserDefaults(suiteName: "HomeChatColorsPanelTests.\(UUID().uuidString)"))
        let store = HomeChatColorStore(defaults: defaults)
        let panel = HomeChatColorsPanel(store: store, design: DesignSettings())
        panel.show(conversation: "chat", name: "Ada", over: nil)
        let window = try #require(panel.window)
        window.orderOut(nil)
        return Rig(store: store, panel: panel, window: window)
    }

    private func views(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views(in:)) }

    private func control(_ label: String, in window: NSPanel) throws -> NSView {
        let content = try #require(window.contentView)
        return try #require(views(in: content).first { $0.accessibilityLabel() == label }, "no control labelled \(label)")
    }

    /// The store's change reaches the view on a later main-actor turn (Observation's onChange):
    /// waits for `condition`, at most two seconds.
    private func settle(until condition: () throws -> Bool) async rethrows {
        let deadline = ContinuousClock.now + .seconds(2)
        while try !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func thePanelBuildsNoHostingView() throws {
        let rig = try rig()
        let content = try #require(rig.window.contentView)
        let hosting = views(in: content).filter { String(describing: type(of: $0)).contains("NSHostingView") }
        #expect(hosting.isEmpty, "\(hosting)")
        #expect(rig.window.title == "Chat Colors — Ada")
        #expect(content.fittingSize.width == 340)
    }

    @Test func aSwatchStoresItsColourAndShowsSelected() async throws {
        let rig = try rig()
        let green = try control("#34C759", in: rig.window)
        let standard = try control("Default", in: rig.window)
        #expect(standard.isAccessibilitySelected())
        #expect(!green.isAccessibilitySelected())
        #expect(green.accessibilityPerformPress())
        #expect(rig.store.colors(for: "chat").hexSummary == "sent=#34C759")
        await settle { green.isAccessibilitySelected() }
        #expect(green.isAccessibilitySelected())
        #expect(!standard.isAccessibilitySelected())
        #expect(green.themedToolTip == "#34C759")
    }

    @Test func aChangeFromElsewhereShowsAndResetClears() async throws {
        let rig = try rig()
        let content = try #require(rig.window.contentView)
        let reset = try #require(views(in: content).compactMap { $0 as? NSButton }.first { $0.title == "Reset to Default" })
        #expect(!reset.isEnabled)
        try rig.store.apply(["received": "#1C2A4A", "receivedText": "#FFFFFF"], reset: false, to: "chat")
        let navy = try control("#1C2A4A", in: rig.window)
        await settle { navy.isAccessibilitySelected() }
        #expect(navy.isAccessibilitySelected())
        #expect(reset.isEnabled)
        reset.performClick(nil)
        #expect(rig.store.colors(for: "chat").hexSummary.isEmpty)
        await settle { !reset.isEnabled }
        #expect(!reset.isEnabled)
        #expect(!navy.isAccessibilitySelected())
    }
}
