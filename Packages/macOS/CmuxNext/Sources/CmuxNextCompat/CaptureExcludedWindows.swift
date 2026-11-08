public import CoreGraphics
import Foundation

/// SECURITY: the app's windows that cmux's own screen captures leave out (screen sharing, its screen
/// recorders): a prompt only the person at this Mac may see, such as the join consent ask or a revealed
/// password. Such a window also sets `NSWindow.sharingType = .none`, but that only asks captures to skip
/// it: since macOS 15.4 a ScreenCaptureKit capture may still show it, and another app's capture is not
/// ours to control. So every capture cmux makes reads this list and leaves these windows out by id.
///
/// Ids are window numbers (`NSWindow.windowNumber`, ScreenCaptureKit's `windowID`). The window's owner
/// inserts it once the window has a number (after it first orders in) and removes it when it hides.
public final class CaptureExcludedWindows: Sendable {
    /// The app's one list.
    public static let shared = CaptureExcludedWindows()

    private let state = Mutex<(ids: Set<CGWindowID>, observers: [UUID: @Sendable () -> Void])>(([], [:]))

    public init() {}

    /// The windows to leave out now.
    public var windowIDs: Set<CGWindowID> {
        state.withLock { $0.ids }
    }

    /// Leaves `id` out of every capture cmux makes from now on; observers hear it at once.
    public func insert(_ id: CGWindowID) {
        guard id > 0 else { return }
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            guard state.ids.insert(id).inserted else { return [] }
            return Array(state.observers.values)
        }
        for observer in observers { observer() }
    }

    /// `id` may show in captures again.
    public func remove(_ id: CGWindowID) {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            guard state.ids.remove(id) != nil else { return [] }
            return Array(state.observers.values)
        }
        for observer in observers { observer() }
    }

    /// Calls `changed` whenever the list changes, until the returned token is released.
    public func observe(_ changed: @escaping @Sendable () -> Void) -> Observation {
        let key = UUID()
        state.withLock { $0.observers[key] = changed }
        return Observation { [weak self] in self?.state.withLock { _ = $0.observers.removeValue(forKey: key) } }
    }

    /// Ends an ``observe(_:)`` when released.
    public final class Observation: Sendable {
        private let end: @Sendable () -> Void

        init(_ end: @escaping @Sendable () -> Void) {
            self.end = end
        }

        deinit { end() }
    }
}
