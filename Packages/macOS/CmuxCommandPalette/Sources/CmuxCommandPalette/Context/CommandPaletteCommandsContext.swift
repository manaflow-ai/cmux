import Foundation

/// Context handed to command-list builders: the gating snapshot.
public struct CommandPaletteCommandsContext {
    /// The context snapshot commands are gated on.
    public let snapshot: CommandPaletteContextSnapshot

    /// Creates a commands context.
    public init(snapshot: CommandPaletteContextSnapshot) {
        self.snapshot = snapshot
    }
}
