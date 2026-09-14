import Foundation

extension UserDefaultsSettingsStore {
    /// Returns a bounded stream of UserDefaults change signals.
    ///
    /// The NotificationCenter observer is intentionally synchronous and
    /// queue-free: it only yields into the stream and returns on the posting
    /// thread. Consumers choose their actor when they iterate the stream, so a
    /// background UserDefaults writer never waits for the main actor.
    ///
    /// - Parameters:
    ///   - notificationCenter: The notification center to observe.
    ///   - observedDefaultsID: When supplied, only notifications whose object
    ///     has this identity are yielded. `nil` observes all defaults changes.
    /// - Returns: A stream that yields once for each UserDefaults change and
    ///   removes its observer when cancelled or terminated.
    public nonisolated static func changeSignals(
        notificationCenter: NotificationCenter = .default,
        observedDefaultsID: ObjectIdentifier? = nil
    ) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = NotificationObserverToken(
                notificationCenter.addObserver(
                    forName: UserDefaults.didChangeNotification,
                    object: nil,
                    queue: nil
                ) { notification in
                    if let observedDefaultsID,
                       notification.object.map({ ObjectIdentifier($0 as AnyObject) }) != observedDefaultsID {
                        return
                    }
                    continuation.yield(())
                },
                notificationCenter: notificationCenter
            )
            continuation.onTermination = { _ in
                token.remove()
            }
        }
    }
}
