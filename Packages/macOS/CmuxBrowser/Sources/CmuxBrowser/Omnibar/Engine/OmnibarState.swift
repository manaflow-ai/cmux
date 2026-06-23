import Foundation

/// The omnibar input state machine: the focused/editing buffer plus the current
/// suggestion list and selection.
///
/// State transitions are driven by `reduce(_:)`, the byte-faithful lift of the
/// legacy top-level `omnibarReduce`. The reducer is the single mutator of this
/// value and returns the side effects (`OmnibarEffects`) the view must perform;
/// the value type itself touches no AppKit/SwiftUI.
public struct OmnibarState: Equatable, Sendable {
    public var isFocused: Bool = false
    public var currentURLString: String = ""
    public var buffer: String = ""
    public var suggestions: [OmnibarSuggestion] = []
    public var selectedSuggestionIndex: Int = 0
    public var selectedSuggestionID: String?
    /// True only while the current suggestion selection came from an explicit
    /// user action (arrow keys, Ctrl+N/P). Automatic highlighting (preferred
    /// autocompletion pick, popup reopen, pointer hover) leaves this false so
    /// a row auto-selected for an older query can never hijack Return.
    public var selectionIsExplicit: Bool = false
    public var isUserEditing: Bool = false

    public init() {}

    /// Applies `event`, mutating the state in place, and returns the side
    /// effects the view must perform.
    @discardableResult
    public mutating func reduce(_ event: OmnibarEvent) -> OmnibarEffects {
        var effects = OmnibarEffects()

        switch event {
        case .focusGained(let url, let shouldSelectAll):
            isFocused = true
            currentURLString = url
            buffer = url
            isUserEditing = false
            suggestions = []
            selectedSuggestionIndex = 0
            selectedSuggestionID = nil
            selectionIsExplicit = false
            effects.shouldSelectAll = shouldSelectAll
            effects.shouldCancelPendingSuggestionRefresh = true

        case .focusReasserted(let shouldSelectAll):
            isFocused = true
            effects.shouldSelectAll = shouldSelectAll
            if shouldSelectAll {
                // A Cmd+L style reassert restarts editing from the full selected
                // text; an earlier arrow selection no longer reflects Return
                // intent. Plain focus restoration (no select-all) keeps it.
                selectionIsExplicit = false
            }

        case .focusLostRevertBuffer(let url):
            isFocused = false
            currentURLString = url
            buffer = url
            isUserEditing = false
            suggestions = []
            selectedSuggestionIndex = 0
            selectedSuggestionID = nil
            selectionIsExplicit = false
            effects.shouldCancelPendingSuggestionRefresh = true

        case .focusLostPreserveBuffer(let url):
            isFocused = false
            currentURLString = url
            isUserEditing = false
            suggestions = []
            selectedSuggestionIndex = 0
            selectedSuggestionID = nil
            selectionIsExplicit = false
            effects.shouldCancelPendingSuggestionRefresh = true

        case .panelURLChanged(let url):
            currentURLString = url
            if !isUserEditing {
                buffer = url
                suggestions = []
                selectedSuggestionIndex = 0
                selectedSuggestionID = nil
                selectionIsExplicit = false
                effects.shouldCancelPendingSuggestionRefresh = true
            }

        case .bufferChanged(let newValue):
            let bufferChanged = buffer != newValue
            buffer = newValue
            if isFocused {
                isUserEditing = (newValue != currentURLString)
                selectedSuggestionIndex = 0
                selectedSuggestionID = nil
                selectionIsExplicit = false
                effects.shouldRefreshSuggestions = true
                effects.shouldClearInlineCompletion = bufferChanged
            }

        case .suggestionsUpdated(let items):
            let previousItems = suggestions
            let previousSelectedID = selectedSuggestionID
            suggestions = items
            if items.isEmpty {
                selectedSuggestionIndex = 0
                selectedSuggestionID = nil
                selectionIsExplicit = false
            } else if let previousSelectedID,
                      let existingIdx = items.firstIndex(where: { $0.id == previousSelectedID }) {
                // Same row carried across a refresh: an explicit selection stays explicit.
                selectedSuggestionIndex = existingIdx
                selectedSuggestionID = items[existingIdx].id
            } else if let preferredSuggestionIndex = BrowserOmnibarSuggestionBuilder.preferredAutocompletionSuggestionIndex(
                suggestions: items,
                query: buffer
            ) {
                selectedSuggestionIndex = preferredSuggestionIndex
                selectedSuggestionID = items[preferredSuggestionIndex].id
                selectionIsExplicit = false
            } else if previousItems.isEmpty {
                // Popup reopened: start keyboard focus from the first row.
                selectedSuggestionIndex = 0
                selectedSuggestionID = items[0].id
                selectionIsExplicit = false
            } else {
                selectedSuggestionIndex = min(max(0, selectedSuggestionIndex), items.count - 1)
                selectedSuggestionID = items[selectedSuggestionIndex].id
                selectionIsExplicit = false
            }

        case .moveSelection(let delta):
            guard !suggestions.isEmpty else { break }
            selectedSuggestionIndex = min(
                max(0, selectedSuggestionIndex + delta),
                suggestions.count - 1
            )
            selectedSuggestionID = suggestions[selectedSuggestionIndex].id
            selectionIsExplicit = true

        case .highlightIndex(let idx):
            guard !suggestions.isEmpty else { break }
            selectedSuggestionIndex = min(max(0, idx), suggestions.count - 1)
            selectedSuggestionID = suggestions[selectedSuggestionIndex].id
            // Pointer hover tracks the highlight but is not an explicit selection:
            // the popup can appear underneath a stationary cursor.
            selectionIsExplicit = false

        case .escape:
            guard isFocused else { break }
            // Chrome semantics:
            // - If user input is in progress OR the popup is open: revert to the page URL and select-all.
            // - Otherwise: exit omnibar focus.
            if isUserEditing || !suggestions.isEmpty {
                isUserEditing = false
                buffer = currentURLString
                suggestions = []
                selectedSuggestionIndex = 0
                selectedSuggestionID = nil
                selectionIsExplicit = false
                effects.shouldSelectAll = true
                effects.shouldCancelPendingSuggestionRefresh = true
            } else {
                effects.shouldBlurToWebView = true
            }
        }

        return effects
    }
}

/// An input or focus event the omnibar state machine reduces.
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

/// Side effects an `OmnibarState.reduce(_:)` transition asks the view to
/// perform; the pure state machine never performs them itself.
public struct OmnibarEffects: Equatable, Sendable {
    public var shouldSelectAll: Bool = false
    public var shouldBlurToWebView: Bool = false
    public var shouldRefreshSuggestions: Bool = false
    public var shouldClearInlineCompletion: Bool = false
    public var shouldCancelPendingSuggestionRefresh: Bool = false

    public init() {}
}
