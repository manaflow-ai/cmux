public import Foundation

extension NotificationCenter {
    /// Observes preference changes on the main actor without blocking background writers.
    ///
    /// Main-thread posts retain synchronous delivery. Background posts schedule
    /// the callback and return before it runs. Foundation's `queue: .main`
    /// observer blocks the posting thread, which can deadlock a lazy initializer
    /// when the main thread is waiting for its value.
    ///
    /// - Parameters:
    ///   - object: The preferences object to observe, or `nil` for all objects.
    ///   - handler: The main-actor action that re-reads the current preferences.
    /// - Returns: An observer token to remove with `removeObserver(_:)` at teardown.
    public func addUserDefaultsObserver(
        object: AnyObject? = nil,
        using handler: @escaping @MainActor @Sendable () -> Void
    ) -> any NSObjectProtocol {
        // This callback is the Foundation notification boundary. Never make a
        // preference writer wait for an operation on the main queue.
        addObserver(forName: UserDefaults.didChangeNotification, object: object, queue: nil) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler() }
            } else {
                Task { @MainActor in handler() }
            }
        }
    }
}
