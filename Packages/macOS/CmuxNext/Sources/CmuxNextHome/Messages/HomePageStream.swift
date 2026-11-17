public import CmuxNextPages
public import CmuxNextSettings
import CmuxNextCompat
import Foundation

/// One host stream of a Home page (`appearance`, `headerPanels`, `needsYou` on the Messages page):
/// every listener gets the current value on subscribe, then each change. A stream made with a
/// `read` follows it through Observation while anyone listens (no polling; the observation ends
/// with the last listener); one made without is pushed (``publish(_:)``).
@MainActor
public final class HomePageStream {
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var watch: Task<Void, Never>?
    private let read: (@MainActor () -> JSONValue)?
    private var value: JSONValue

    /// A stream that follows `read`.
    public init(observing read: @escaping @MainActor () -> JSONValue) {
        self.read = read
        value = .null
    }

    /// A pushed stream, starting at `initial`.
    public init(initial: JSONValue) {
        read = nil
        value = initial
    }

    nonisolated deinit {
        watch?.cancel()
    }

    /// Adds a page listener: it gets the value now and each change until the subscription ends.
    public func subscribe(_ onEvent: @escaping @MainActor (JSONValue) -> Void) -> PageSubscription {
        let key = UUID()
        listeners[key] = onEvent
        if let read {
            if watch == nil { restart() } else { onEvent(read()) }
        } else {
            onEvent(value)
        }
        return PageSubscription { [weak self] in
            guard let self else { return }
            listeners[key] = nil
            if listeners.isEmpty { stop() }
        }
    }

    /// Reads again from scratch (what `read` reads changed beyond Observation: another conversation).
    public func restart() {
        stop()
        guard let read, !listeners.isEmpty else { return }
        // task-owner: lives while the page listens (ended with the last listener or the next restart); event-driven (Observation)
        watch = Task { [weak self] in
            for await value in ObservationStream({ read() }) {
                self?.publish(value)
            }
        }
    }

    /// Sends `value` to every listener.
    public func publish(_ value: JSONValue) {
        self.value = value
        for listener in listeners.values { listener(value) }
    }

    private func stop() {
        watch?.cancel()
        watch = nil
    }
}
