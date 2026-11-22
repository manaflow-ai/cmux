public import AppKit

/// A window whose close key does its own close instead of closing the window (DevTools hides its inspector
/// through its owner). The close key calls ``closeFromKey()``; every other window closes with
/// `NSWindow.closeWithoutButtonFlash()`, never `performClose(_:)` (its button flash is a nested run loop of
/// about 100 ms on the key turn).
///
/// ```swift
/// final class InspectorPanel: NSPanel, WindowKeyClosing {
///     var onClose: (() -> Void)?
///     func closeFromKey() { onClose?() }
/// }
/// ```
@MainActor
public protocol WindowKeyClosing: NSWindow {
    /// The close key's close of this window.
    func closeFromKey()
}

extension NSWindow {
    /// The close key's close of a window that closes as a whole: its own close (``WindowKeyClosing``), else
    /// as its close button does, in the key's turn (``closeWithoutButtonFlash(requiresCloseButton:)``: never
    /// `performClose(_:)`, whose button flash is a nested run loop of about 100 ms).
    @MainActor
    public func closeFromCloseKey() {
        if let own = self as? any WindowKeyClosing {
            own.closeFromKey()
        } else {
            closeWithoutButtonFlash()
        }
    }
}
