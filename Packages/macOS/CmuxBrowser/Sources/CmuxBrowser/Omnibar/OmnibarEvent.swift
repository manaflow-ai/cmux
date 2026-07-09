/// An input to the omnibar reducer describing a focus change, edit, suggestion
/// update, selection move, or escape. Pure value: the reducer maps an event plus
/// the current `OmnibarState` to a new state and an `OmnibarEffects`.
public enum OmnibarEvent: Equatable, Sendable {
    case focusGained(currentURLString: String, shouldSelectAll: Bool = false)
    case focusReasserted(shouldSelectAll: Bool = true)
    case focusLostRevertBuffer(currentURLString: String)
    case focusLostPreserveBuffer(currentURLString: String)
    case panelURLChanged(currentURLString: String)
    case bufferChanged(String)
    case suggestionsUpdated([OmnibarSuggestion])
    case moveSelection(delta: Int)
    case highlightIndex(Int)
    case escape
}
