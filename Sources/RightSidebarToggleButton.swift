import AppKit
import CmuxSettings
import SwiftUI

/// The persistent right-sidebar show/hide button.
///
/// Every placement renders this one view, so the glyph, tooltip, and action
/// stay identical. The action resolves the button's own window and runs the
/// shared ⌘⌥B path (`toggleRightSidebarInActiveMainWindow`), which toggles
/// that window's sidebar and restores terminal focus on hide.
struct RightSidebarToggleButton: View {
    let placement: RightSidebarToggleButtonPlacement
    let isRightSidebarVisible: Bool

    @State private var hostWindow = RightSidebarToggleHostWindowReference()
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        let _ = keyboardShortcutSettingsObserver.revision
        Button(action: toggle) {
            SidebarGlyph(iconSize: HeaderChromeControlMetrics.iconSize, side: .trailing)
        }
        .buttonStyle(RightSidebarHeaderIconButtonStyle(iconGeometryKeyPrefix: "rightSidebarToggleButtonIcon"))
        .frame(
            width: RightSidebarToggleButtonLayout.buttonSize,
            height: RightSidebarToggleButtonLayout.buttonSize
        )
        .background(RightSidebarToggleHostWindowReader(reference: hostWindow))
        .safeHelp(
            KeyboardShortcutSettings.Action.toggleRightSidebar.tooltip(
                isRightSidebarVisible
                    ? String(localized: "rightSidebar.toggleButton.hide.tooltip", defaultValue: "Hide Right Sidebar")
                    : String(localized: "rightSidebar.toggleButton.show.tooltip", defaultValue: "Show Right Sidebar")
            )
        )
        .accessibilityLabel(String(localized: "rightSidebar.toggleButton.accessibilityLabel", defaultValue: "Toggle Right Sidebar"))
        .accessibilityValue(
            isRightSidebarVisible
                ? String(localized: "rightSidebar.toggleButton.accessibilityValue.shown", defaultValue: "Shown")
                : String(localized: "rightSidebar.toggleButton.accessibilityValue.hidden", defaultValue: "Hidden")
        )
        .accessibilityIdentifier("RightSidebarToggleButton.\(placement.rawValue)")
        .titlebarInteractiveControl()
    }

    private func toggle() {
        #if DEBUG
        cmuxDebugLog("rightSidebar.toggleButton placement=\(placement.rawValue)")
        #endif
        let window = hostWindow.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        if AppDelegate.shared?.toggleRightSidebarInActiveMainWindow(preferredWindow: window) != true {
            NSSound.beep()
        }
    }
}

/// Weak reference to the window hosting a toggle button, filled by AppKit when
/// the button's backing view moves between windows.
@MainActor
final class RightSidebarToggleHostWindowReference {
    weak var window: NSWindow?
}

private struct RightSidebarToggleHostWindowReader: NSViewRepresentable {
    let reference: RightSidebarToggleHostWindowReference

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.reference = reference
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.reference = reference
        reference.window = nsView.window
    }

    final class ReaderView: NSView {
        var reference: RightSidebarToggleHostWindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
