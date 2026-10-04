public import Foundation

/// One DevTools protocol event of a page (`Runtime.bindingCalled`, …):
/// the method and its params as a JSON object.
public nonisolated struct BrowserDevToolsEvent: Equatable, Sendable {
    public var method: String
    public var params: String

    public init(method: String, params: String) {
        self.method = method
        self.params = params
    }
}

/// The subscribers of one tab's DevTools events. Events reach Swift only
/// while there is at least one (the shim drops the rest), so a tab nobody
/// watches pays nothing.
final class CEFDevToolsEventFanout {
    private var continuations: [UUID: AsyncStream<BrowserDevToolsEvent>.Continuation] = [:]

    var hasSubscribers: Bool { !continuations.isEmpty }

    /// Adds a subscriber; `changed` runs when the subscriber count goes
    /// from 0 to 1 (true) or back to 0 (false).
    func subscribe(changed: @escaping @Sendable @MainActor (Bool) -> Void) -> AsyncStream<BrowserDevToolsEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BrowserDevToolsEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let wasEmpty = continuations.isEmpty
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.continuations.removeValue(forKey: id) != nil, self.continuations.isEmpty else { return }
                changed(false)
            }
        }
        if wasEmpty { changed(true) }
        return stream
    }

    func deliver(_ event: BrowserDevToolsEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    /// The browser is gone: every stream ends.
    func finishAll() {
        let all = continuations.values
        continuations.removeAll()
        for continuation in all { continuation.finish() }
    }
}

extension CEFTab {
    /// This page's DevTools protocol events, for domains and bindings turned
    /// on with ``devTools(method:params:)`` (for example `Runtime.addBinding`
    /// and its `Runtime.bindingCalled`). The stream ends when the browser
    /// closes; ending it early stops the shim forwarding once no other
    /// subscriber is left.
    public func devToolsEventStream() -> AsyncStream<BrowserDevToolsEvent> {
        devToolsEvents.subscribe { [weak self] on in
            guard let self, let browserID = self.browserID else { return }
            self.runtime.shim?.devToolsWatchEvents(browserID, on ? 1 : 0)
        }
    }
}
