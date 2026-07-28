import Foundation

/// Maps command identifiers to their runnable handlers. The palette resolves
/// activations through this registry so command declarations
/// (``CommandPaletteCommandContribution``) stay separate from host behavior.
public struct CommandPaletteHandlerRegistry {
    private var handlers: [String: CmuxActionHandler] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Registers an argument-aware action handler for `commandId`.
    public mutating func register(
        commandId: String,
        handler: @escaping CmuxActionHandler
    ) {
        guard handlers[commandId] == nil else { return }
        handlers[commandId] = handler
    }

    /// The handler registered for `commandId`, when any.
    public func handler(for commandId: String) -> CmuxActionHandler? {
        handlers[commandId]
    }

    /// Every command identifier claimed by a registered handler.
    public var commandIDs: Set<String> {
        Set(handlers.keys)
    }
}
