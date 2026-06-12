import Foundation

/// Field-editor state captured synchronously at Return time. The published
/// SwiftUI buffer and the debounced suggestion list can lag behind what the
/// field actually displays, so submit decisions must start from this snapshot.
struct OmnibarLiveFieldSnapshot: Equatable {
    var text: String
    var selectionRange: NSRange?
    var hasMarkedText: Bool
}

enum OmnibarSubmitDecision: Equatable {
    case commitSelectedSuggestion
    case navigate(text: String)
}

/// Decides whether Return commits the selected suggestion row or navigates
/// the omnibar text.
func omnibarSubmitDecision(
    liveField: OmnibarLiveFieldSnapshot?,
    state: OmnibarState,
    inlineCompletion: OmnibarInlineCompletion?,
    canInteractWithSuggestions: Bool
) -> OmnibarSubmitDecision {
    if canInteractWithSuggestions {
        return .commitSelectedSuggestion
    }
    return .navigate(text: state.buffer)
}
