import Foundation

/// One ``MainActorHandlers/add(_:)`` registration: releasing it, on any thread, or calling
/// ``cancel()`` stops the calls.
public nonisolated final class MainActorHandlerRegistration<Value: Sendable>: Sendable {
    private let handlers: MainActorHandlers<Value>
    private let id: UUID

    init(handlers: MainActorHandlers<Value>, id: UUID) {
        self.handlers = handlers
        self.id = id
    }

    /// Stops the calls now (also happens when the registration is released).
    public func cancel() {
        handlers.remove(id)
    }

    deinit {
        handlers.remove(id)
    }
}
