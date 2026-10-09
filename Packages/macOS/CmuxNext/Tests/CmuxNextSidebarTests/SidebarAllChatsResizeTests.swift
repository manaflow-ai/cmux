import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Lawrence 2026-10-09: the open All chats section resizes from a divider on its top edge. One
/// third by default; a drag changes it (clamped: header + 3 rows to the sidebar minus the list's
/// room); remembered per Mac; double-click resets; VoiceOver sees an adjustable splitter.
@MainActor @Suite(.serialized) struct SidebarAllChatsResizeTests {
    final class Provider: SidebarAppSectionProvider {
        let view: SidebarChatsView
        var onContentChange: (() -> Void)?
        init(defaults: UserDefaults) {
            view = SidebarChatsView(defaults: defaults)
            view.update((0..<40).map { SidebarChatsView.Row(id: "codex:\($0)", title: "Chat \($0)", harness: "codex", brand: nil) },
                        enabled: true, ready: true)
            if !view.isExpanded { view.toggleExpanded() }
        }
        func title(for contribution: String) -> String? { nil }
        func makeView(for contribution: String) -> NSView? { contribution == SidebarChatsView.contribution ? view : nil }
        func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat { view.preferredHeight }
    }

    private func sidebar(_ provider: Provider, height: CGFloat = 900) -> SidebarView {
        let model = SidebarModel()
        model.layout = SidebarLayoutDocument.defaults.chatsLayout(enabled: true)
        let sidebar = SidebarView(model: model)
        sidebar.appSections = provider
        provider.view.onLayoutChange = { [weak sidebar] in sidebar?.needsLayout = true; sidebar?.layout() }
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.layout()
        return sidebar
    }

    @Test func draggingTheDividerResizesAndIsRemembered() {
        let defaults = UserDefaults(suiteName: "chats-resize-\(UUID())")!
        let provider = Provider(defaults: defaults)
        let view = sidebar(provider)
        #expect(abs(provider.view.frame.height - 300) <= 1, "one third of 900 by default")
        let divider = provider.view.divider
        #expect(!divider.isHidden && divider.frame.minY == 0, "the divider is the section's top edge")
        divider.onDragStart?()
        divider.onDrag?(-150)  // up 150 pt: taller
        view.layout()
        #expect(abs(provider.view.frame.height - 450) <= 1)
        let again = SidebarChatsView(defaults: defaults)
        #expect(abs((again.customShare ?? 0) - 0.5) < 0.01, "kept on this Mac")
        divider.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
        view.layout()
        #expect(abs(provider.view.frame.height - 300) <= 1, "double-click resets to one third")
        #expect(SidebarChatsView(defaults: defaults).customShare == nil)
    }

    @Test func aDragIsClamped() {
        let rows = Metrics.sidebarRowHeight
        let tiny = SidebarChatsView.clampedShare(height: 10, sidebarHeight: 900, reserved: SidebarChatsView.reservedHeight)
        #expect(abs(tiny * 900 - rows * 4) < 0.5, "at least the header and three rows")
        let huge = SidebarChatsView.clampedShare(height: 2000, sidebarHeight: 900, reserved: SidebarChatsView.reservedHeight)
        #expect(abs(huge * 900 - (900 - SidebarChatsView.reservedHeight)) < 0.5, "the list above keeps its room")
    }

    @Test func voiceOverSeesAnAdjustableSplitter() {
        let provider = Provider(defaults: UserDefaults(suiteName: "chats-resize-ax-\(UUID())")!)
        let view = sidebar(provider)
        let divider = provider.view.divider
        #expect(divider.isAccessibilityElement() && divider.accessibilityRole() == .splitter)
        #expect(divider.accessibilityValue() as? String == "33%")
        let before = provider.view.frame.height
        #expect(divider.accessibilityPerformIncrement())
        view.layout()
        #expect(abs(provider.view.frame.height - (before + Metrics.sidebarRowHeight)) <= 1, "one row taller")
    }
}
