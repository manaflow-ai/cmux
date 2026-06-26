public import AppKit

/// Backing `NSView` for ``AppKitContextMenuCapture`` that hit-tests only
/// right-clicks and control-clicks, presenting an AppKit context menu on
/// demand. Left-click selection, drags, double-taps, and hover continue to
/// hit-test through to the underlying SwiftUI view tree — the same technique as
/// `MiddleClickCaptureView`.
public final class AppKitContextMenuCaptureView: NSView {
    /// Builds the menu elements on demand (each right-click), so the menu always
    /// reflects current state and no responder is retained between invocations.
    public var elementsProvider: (@MainActor () -> [CmuxContextMenuElement])?

    /// Claims only contextual-menu events; everything else passes through so
    /// SwiftUI gestures (tap, drag, hover) keep working unchanged.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown:
            return self
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return self
        default:
            return nil
        }
    }

    /// Presents the context menu for a right-click.
    public override func rightMouseDown(with event: NSEvent) {
        presentMenu(for: event)
    }

    /// Presents the context menu for a control-click; other mouse-downs that
    /// reach here (they should not, given `hitTest`) fall through to `super`.
    public override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        presentMenu(for: event)
    }

    /// VoiceOver "show menu" action (rotor / two-finger double-tap). SwiftUI's
    /// `.contextMenu` wires this automatically; restore parity for adopting rows.
    public override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = buildMenu() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }

    private func presentMenu(for event: NSEvent) {
        guard let menu = buildMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func buildMenu() -> CmuxContextMenu? {
        guard let elements = elementsProvider?(), !elements.isEmpty else { return nil }
        let menu = CmuxContextMenu(from: elements)
        guard !menu.items.isEmpty else { return nil }
        return menu
    }
}
