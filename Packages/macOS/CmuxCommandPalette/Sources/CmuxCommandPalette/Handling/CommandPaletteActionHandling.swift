import Foundation

/// Host seam through which palette command handlers are registered and
/// resolved. The host (the app's composition root) conforms, the palette
/// domain depends only on this protocol, so the package never reaches back
/// into app types.
@MainActor
public protocol CommandPaletteActionHandling {
    /// Registers `handler` as the action for `commandId`.
    func register(commandId: String, handler: @escaping () -> Void)

    /// The action registered for `commandId`, when any.
    func handler(for commandId: String) -> (() -> Void)?
}
