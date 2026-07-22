import Foundation

/// Maps command identifiers to their runnable handlers. The palette resolves
/// activations through this registry so command declarations
/// (``CommandPaletteCommandContribution``) stay separate from host behavior.
public struct CommandPaletteHandlerRegistry {
    private var handlers: [String: CmuxActionHandler] = [:]

    /// Creates an empty registry.
    public init() {}

    /// Registers `handler` for `commandId`; the first definition owns the ID.
    public mutating func register(
        commandId: String,
        handler: @escaping @MainActor () -> Void
    ) {
        guard handlers[commandId] == nil else { return }
        handlers[commandId] = { _ in
            handler()
            return .completed
        }
    }

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
}
