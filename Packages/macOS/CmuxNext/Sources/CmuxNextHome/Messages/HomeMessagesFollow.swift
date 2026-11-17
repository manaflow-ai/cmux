import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings

/// A Messages page stream that follows what the host reads, as the native sheets followed their
/// models while they showed (Group Info's `actions.info(id)`, Message Requests' `items`): the page
/// hears `read()` when it subscribes and again after each change of an observable value it read.
/// `read()` answering nil means what it follows is gone (a conversation left or deleted): the page
/// hears ``gone`` once and the stream ends (the sheet closes, as the native one did).
@MainActor
public struct HomeMessagesFollow {
    public init() {}
    /// The last event of a stream whose subject is gone.
    public static let gone: JSONValue = .object(["gone": .bool(true)])

    public static func start(_ read: @escaping @MainActor @Sendable () -> JSONValue?,
                             onEvent: @escaping @MainActor (JSONValue) -> Void) -> PageSubscription {
        // task-owner: lives while the page listens (cancelled with its subscription) or until what it follows is gone; event-driven (Observation)
        let watch = Task {
            for await value in ObservationStream({ read() }) {
                guard let value else { onEvent(gone); return }
                onEvent(value)
            }
        }
        return PageSubscription { watch.cancel() }
    }
}
