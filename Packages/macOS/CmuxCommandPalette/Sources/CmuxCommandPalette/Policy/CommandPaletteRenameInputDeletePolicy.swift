public import SwiftUI

/// Decides whether a delete-backward in the palette's rename input should pop
/// the palette back to its command list instead of editing the draft text:
/// only when no modifier keys are held and the rename draft is already empty.
public struct CommandPaletteRenameInputDeletePolicy: Sendable {
    /// The current rename draft text.
    public let renameDraft: String
    /// The modifier keys held during the delete-backward.
    public let modifiers: EventModifiers

    /// Captures the rename-input delete inputs to evaluate.
    public init(renameDraft: String, modifiers: EventModifiers) {
        self.renameDraft = renameDraft
        self.modifiers = modifiers
    }

    /// Whether the delete should pop the palette back to the command list.
    public var shouldPopToCommands: Bool {
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return false }
        return renameDraft.isEmpty
    }
}
