public import CmuxNextSettings
public import Foundation

/// A yes-or-no a native host tells its page as a stream: each subscription hears the value now,
/// then every change, as `{<key>: Bool}`. The sidebar's Updated card tells its page whether the
/// pointer is on it (WebKit sends a page no pointer moves while another of the app's windows has
/// the key).
@MainActor
public final class PageFlagStream {
    /// The event's one field.
    public let key: String
    public var value = false {
        didSet {
            guard value != oldValue else { return }
            for listener in listeners.values { listener(value) }
        }
    }

    private var listeners: [UUID: @MainActor (Bool) -> Void] = [:]

    public init(key: String) {
        self.key = key
    }

    /// One page subscription: the value now, then each change, until it is cancelled.
    public func subscribe(onEvent: @escaping @MainActor (JSONValue) -> Void) -> PageSubscription {
        let id = UUID(), key = key
        let send: @MainActor (Bool) -> Void = { onEvent(.object([key: .bool($0)])) }
        listeners[id] = send
        send(value)
        return PageSubscription { [weak self] in self?.listeners[id] = nil }
    }
}
