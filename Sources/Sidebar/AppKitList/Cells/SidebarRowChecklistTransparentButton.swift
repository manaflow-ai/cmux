import AppKit
import CmuxWorkspaces
import SwiftUI

/// Transparent full-frame click target (the tap-to-edit overlay on item
/// text; legacy: `.contentShape(Rectangle()).onTapGesture`).
@MainActor
final class SidebarRowChecklistTransparentButton: NSControl {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Button.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}
