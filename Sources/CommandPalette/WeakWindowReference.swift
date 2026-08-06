import AppKit

@MainActor
final class WeakWindowReference {
    weak var window: NSWindow?

    init(_ window: NSWindow? = nil) {
        self.window = window
    }
}
