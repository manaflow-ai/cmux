import AppKit

/// Preserves window-list order without taking ownership of an AppKit window.
final class WeakWindowReference {
    weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
    }
}
