import Foundation

/// Maps command identifiers to their runnable handlers. The palette resolves
/// activations through this registry so command declarations
/// (``CommandPaletteCommandContribution``) stay separate from host behavior.
public struct CommandPaletteHandlerRegistry {
    private var handlers: [String: () -> Void] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Registers `handler` for `commandId`, replacing any existing handler.
    public mutating func register(commandId: String, handler: @escaping () -> Void) {
        handlers[commandId] = handler
    }

    /// The handler registered for `commandId`, when any.
    public func handler(for commandId: String) -> (() -> Void)? {
        handlers[commandId]
    }
}
