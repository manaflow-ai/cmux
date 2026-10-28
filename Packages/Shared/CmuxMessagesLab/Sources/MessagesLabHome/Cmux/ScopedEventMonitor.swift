// cmux: an NSEvent local monitor owned like a stored value. Not a vendored file.
import AppKit

/// An NSEvent local monitor that is removed when this object is released.
///
/// An owner keeps it in a stored property and sets that to nil to stop it, instead of keeping AppKit's
/// `Any` token and removing it in its `deinit` (a main-actor class's `deinit` is nonisolated, and the token
/// is not `Sendable`). `NSEvent` is not main-actor isolated, so this `deinit` needs no isolation.
final class ScopedEventMonitor {
    private let token: Any

    /// Installs a local monitor for `mask`; nil when AppKit installs none.
    /// - Parameters:
    ///   - mask: The events to see.
    ///   - handler: AppKit's local monitor handler (main thread): the event to dispatch, or nil to drop it.
    @MainActor
    init?(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        guard let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) else { return nil }
        self.token = token
    }

    deinit { NSEvent.removeMonitor(token) }
}
