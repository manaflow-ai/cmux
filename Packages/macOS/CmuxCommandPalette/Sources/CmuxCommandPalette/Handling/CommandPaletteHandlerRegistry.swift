import Foundation

/// Maps command identifiers to their runnable handlers. The palette resolves
/// activations through this registry so command declarations
/// (``CommandPaletteCommandContribution``) stay separate from host behavior.
public struct CommandPaletteHandlerRegistry {
    private var handlers: [String: ([String: String]) -> Void] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Registers a no-argument handler, replacing any existing handler.
    /// - Parameters:
    ///   - commandId: Stable command identity whose handler is replaced.
    ///   - handler: Action that ignores any supplied finite-choice values.
    public mutating func register(commandId: String, handler: @escaping () -> Void) {
        handlers[commandId] = { _ in handler() }
    }

    /// Registers a handler that consumes finite-choice argument values.
    /// - Parameters:
    ///   - commandId: Stable command identity whose handler is replaced.
    ///   - argumentHandler: Action receiving values keyed by argument name.
    public mutating func register(
        commandId: String,
        argumentHandler: @escaping ([String: String]) -> Void
    ) {
        handlers[commandId] = argumentHandler
    }

    /// Returns the handler registered for a command.
    /// - Parameter commandId: Stable command identity to resolve.
    /// - Returns: A handler accepting collected values, or `nil` when unregistered.
    public func handler(for commandId: String) -> (([String: String]) -> Void)? {
        handlers[commandId]
    }
}
