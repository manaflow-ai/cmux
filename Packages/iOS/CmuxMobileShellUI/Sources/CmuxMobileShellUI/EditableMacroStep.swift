import CmuxMobileTerminalKit
import Foundation

/// A ``ToolbarMacroStep`` wrapped with a stable identity so
/// ``CustomToolbarActionEditorView``'s `ForEach` can reorder, delete, and edit
/// steps in place. The identity is view-local only; it is never persisted (the
/// saved macro is just `[ToolbarMacroStep]`).
struct EditableMacroStep: Identifiable, Equatable {
    let id: UUID
    var step: ToolbarMacroStep

    init(id: UUID = UUID(), _ step: ToolbarMacroStep) {
        self.id = id
        self.step = step
    }
}
