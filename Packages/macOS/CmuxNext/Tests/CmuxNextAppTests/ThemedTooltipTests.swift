import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo, 2026-10-12: cmux-next's tooltips were macOS's stock yellow-gray bubble ("Default" on the
/// sidebar's space tile). Controls hand their tooltip to the app's themed one instead: no AppKit
/// `toolTip`, while VoiceOver still reads the same text as the control's help.
@MainActor @Suite(.serialized) struct ThemedTooltipTests {
    @Test func controlsUseTheThemedTooltipNotAppKits() {
        let views: [(NSView, String)] = [
            (SidebarIconButton(icon: .actionClose, label: "Close Workspace"), "Close Workspace"),
            (ChromeIconButton(icon: .navPreviousMatch, label: "Previous Match", action: nil, target: nil), "Previous Match"),
            (GroupCustomSwatchView(label: "Custom Color"), "Custom Color"),
        ]
        for (view, text) in views {
            #expect(view.toolTip == nil, "\(text)")
            #expect(view.accessibilityHelp() == text, "\(text)")
        }
    }
}
