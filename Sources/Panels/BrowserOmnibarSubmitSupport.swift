import CmuxBrowser
import Foundation

// OmnibarLiveFieldSnapshot moved to CmuxBrowser
// (Sources/CmuxBrowser/Omnibar/Engine/OmnibarLiveFieldSnapshot.swift) as a
// Sendable value type, shared between the AppKit omnibar field editor in
// CmuxBrowserUI and this submit-decision logic. Reachable here via `import
// CmuxBrowser` above.

enum OmnibarSubmitDecision: Equatable {
    case commitSelectedSuggestion
    case navigate(text: String)
}

/// Decides whether Return commits the selected suggestion row or navigates
/// the omnibar text.
///
/// The decision starts from the live field editor, not the published SwiftUI
/// state: the published buffer and the debounced suggestion list can lag a
/// fast typist, while the field always holds exactly what the user sees.
/// Return commits a suggestion only when the user explicitly arrow-selected
/// it and the live field still matches the published state that selection was
/// made against; otherwise Return navigates the live field text verbatim.
func omnibarSubmitDecision(
    liveField: OmnibarLiveFieldSnapshot?,
    state: OmnibarState,
    inlineCompletion: OmnibarInlineCompletion?,
    canInteractWithSuggestions: Bool
) -> OmnibarSubmitDecision {
    guard let liveField else {
        if canInteractWithSuggestions && state.selectionIsExplicit {
            return .commitSelectedSuggestion
        }
        return .navigate(text: state.buffer)
    }

    // Resolve what the live field would publish through the same pure helper
    // the per-keystroke path uses (inline-completion and marked-text aware).
    // If that differs from the published buffer, the field is ahead of the
    // state any suggestion selection was computed for.
    let publishedEquivalent = OmnibarInlineCompletion.publishedBufferText(
        fieldValue: liveField.text,
        inlineCompletion: inlineCompletion,
        selectionRange: liveField.selectionRange,
        hasMarkedText: liveField.hasMarkedText
    )
    let fieldMatchesPublishedState = publishedEquivalent == state.buffer
    if canInteractWithSuggestions && state.selectionIsExplicit && fieldMatchesPublishedState {
        return .commitSelectedSuggestion
    }
    return .navigate(text: liveField.text)
}
