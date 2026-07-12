import CmuxBrowser
import Foundation

// MARK: - Omnibar State Machine

struct OmnibarState: Equatable {
    var isFocused: Bool = false
    var currentURLString: String = ""
    var buffer: String = ""
    var suggestions: [OmnibarSuggestion] = []
    var selectedSuggestionIndex: Int = 0
    var selectedSuggestionID: String?
    /// True only while the current suggestion selection came from an explicit
    /// user action (arrow keys, Ctrl+N/P). Automatic highlighting (preferred
    /// autocompletion pick, popup reopen, pointer hover) leaves this false so
    /// a row auto-selected for an older query can never hijack Return.
    var selectionIsExplicit: Bool = false
    var isUserEditing: Bool = false
}

enum OmnibarEvent: Equatable {
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

struct OmnibarEffects: Equatable {
    var shouldSelectAll: Bool = false
    var shouldBlurToWebView: Bool = false
    var shouldRefreshSuggestions: Bool = false
    var shouldClearInlineCompletion: Bool = false
    var shouldCancelPendingSuggestionRefresh: Bool = false
}

@discardableResult
func omnibarReduce(state: inout OmnibarState, event: OmnibarEvent) -> OmnibarEffects {
    var effects = OmnibarEffects()

    switch event {
    case .focusGained(let url, let shouldSelectAll):
        state.isFocused = true
        state.currentURLString = url
        state.buffer = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil
        state.selectionIsExplicit = false
        effects.shouldSelectAll = shouldSelectAll
        effects.shouldCancelPendingSuggestionRefresh = true

    case .focusReasserted(let shouldSelectAll):
        state.isFocused = true
        effects.shouldSelectAll = shouldSelectAll
        if shouldSelectAll {
            // A Cmd+L style reassert restarts editing from the full selected
            // text; an earlier arrow selection no longer reflects Return
            // intent. Plain focus restoration (no select-all) keeps it.
            state.selectionIsExplicit = false
        }

    case .focusLostRevertBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.buffer = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil
        state.selectionIsExplicit = false
        effects.shouldCancelPendingSuggestionRefresh = true

    case .focusLostPreserveBuffer(let url):
        state.isFocused = false
        state.currentURLString = url
        state.isUserEditing = false
        state.suggestions = []
        state.selectedSuggestionIndex = 0
        state.selectedSuggestionID = nil
        state.selectionIsExplicit = false
        effects.shouldCancelPendingSuggestionRefresh = true

    case .panelURLChanged(let url):
        state.currentURLString = url
        if !state.isUserEditing {
            state.buffer = url
            state.suggestions = []
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            state.selectionIsExplicit = false
            effects.shouldCancelPendingSuggestionRefresh = true
        }

    case .bufferChanged(let newValue):
        let bufferChanged = state.buffer != newValue
        state.buffer = newValue
        if state.isFocused {
            state.isUserEditing = (newValue != state.currentURLString)
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            state.selectionIsExplicit = false
            effects.shouldRefreshSuggestions = true
            effects.shouldClearInlineCompletion = bufferChanged
        }

    case .suggestionsUpdated(let items):
        let previousItems = state.suggestions
        let previousSelectedID = state.selectedSuggestionID
        state.suggestions = items
        if items.isEmpty {
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            state.selectionIsExplicit = false
        } else if let previousSelectedID,
                  let existingIdx = items.firstIndex(where: { $0.id == previousSelectedID }) {
            // Same row carried across a refresh: an explicit selection stays explicit.
            state.selectedSuggestionIndex = existingIdx
            state.selectedSuggestionID = items[existingIdx].id
        } else if let preferredSuggestionIndex = omnibarPreferredAutocompletionSuggestionIndex(
            suggestions: items,
            query: state.buffer
        ) {
            state.selectedSuggestionIndex = preferredSuggestionIndex
            state.selectedSuggestionID = items[preferredSuggestionIndex].id
            state.selectionIsExplicit = false
        } else if previousItems.isEmpty {
            // Popup reopened: start keyboard focus from the first row.
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = items[0].id
            state.selectionIsExplicit = false
        } else {
            state.selectedSuggestionIndex = min(max(0, state.selectedSuggestionIndex), items.count - 1)
            state.selectedSuggestionID = items[state.selectedSuggestionIndex].id
            state.selectionIsExplicit = false
        }

    case .moveSelection(let delta):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(
            max(0, state.selectedSuggestionIndex + delta),
            state.suggestions.count - 1
        )
        state.selectedSuggestionID = state.suggestions[state.selectedSuggestionIndex].id
        state.selectionIsExplicit = true

    case .highlightIndex(let idx):
        guard !state.suggestions.isEmpty else { break }
        state.selectedSuggestionIndex = min(max(0, idx), state.suggestions.count - 1)
        state.selectedSuggestionID = state.suggestions[state.selectedSuggestionIndex].id
        // Pointer hover tracks the highlight but is not an explicit selection:
        // the popup can appear underneath a stationary cursor.
        state.selectionIsExplicit = false

    case .escape:
        guard state.isFocused else { break }
        // Chrome semantics:
        // - If user input is in progress OR the popup is open: revert to the page URL and select-all.
        // - Otherwise: exit omnibar focus.
        if state.isUserEditing || !state.suggestions.isEmpty {
            state.isUserEditing = false
            state.buffer = state.currentURLString
            state.suggestions = []
            state.selectedSuggestionIndex = 0
            state.selectedSuggestionID = nil
            state.selectionIsExplicit = false
            effects.shouldSelectAll = true
            effects.shouldCancelPendingSuggestionRefresh = true
        } else {
            effects.shouldBlurToWebView = true
        }
    }

    return effects
}

struct OmnibarSuggestion: Identifiable, Hashable {
    enum Kind: Hashable {
        case search(engineName: String, query: String)
        case navigate(url: String)
        case history(url: String, title: String?)
        case switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?)
        case remote(query: String)
    }

    let kind: Kind

    // Stable identity prevents row teardown/rebuild flicker while typing.
    var id: String {
        switch kind {
        case .search(let engineName, let query):
            return "search|\(engineName.lowercased())|\(query.lowercased())"
        case .navigate(let url):
            return "navigate|\(url.lowercased())"
        case .history(let url, _):
            return "history|\(url.lowercased())"
        case .switchToTab(let tabId, let panelId, let url, _):
            return "switch-tab|\(tabId.uuidString.lowercased())|\(panelId.uuidString.lowercased())|\(url.lowercased())"
        case .remote(let query):
            return "remote|\(query.lowercased())"
        }
    }

    var completion: String {
        switch kind {
        case .search(_, let q): return q
        case .navigate(let url): return url
        case .history(let url, _): return url
        case .switchToTab(_, _, let url, _): return url
        case .remote(let q): return q
        }
    }

    var primaryText: String {
        switch kind {
        case .search(let engineName, let q):
            return "Search \(engineName) for \"\(q)\""
        case .navigate(let url):
            return Self.displayURLText(for: url)
        case .history(let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            return (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? Self.singleLineText(title) : Self.displayURLText(for: url)
        case .remote(let q):
            return q
        }
    }

    var listText: String {
        switch kind {
        case .history(let url, let title), .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            guard !titleOneline.isEmpty else { return Self.displayURLText(for: url) }
            return "\(titleOneline) — \(Self.displayURLText(for: url))"
        default:
            return primaryText
        }
    }

    var secondaryText: String? {
        switch kind {
        case .history(let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        case .switchToTab(_, _, let url, let title):
            let titleOneline = Self.singleLineText(title)
            return titleOneline.isEmpty ? nil : Self.displayURLText(for: url)
        default:
            return nil
        }
    }

    var trailingBadgeText: String? {
        switch kind {
        case .switchToTab:
            return String(localized: "browser.switchToTab", defaultValue: "Switch to tab")
        default:
            return nil
        }
    }

    var isHistoryRemovable: Bool {
        if case .history = kind { return true }
        return false
    }

    static func history(_ entry: BrowserHistoryStore.Entry) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: entry.url, title: entry.title))
    }

    static func history(url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: url, title: title))
    }

    static func search(engineName: String, query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .search(engineName: engineName, query: query))
    }

    static func navigate(url: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .navigate(url: url))
    }

    static func switchToTab(tabId: UUID, panelId: UUID, url: String, title: String?) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .switchToTab(tabId: tabId, panelId: panelId, url: url, title: title))
    }

    private static func singleLineText(_ value: String?) -> String {
        var normalized = (value ?? "").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.contains("  ") {
            let collapsed = normalized.replacingOccurrences(of: "  ", with: " ")
            if collapsed == normalized { break }
            normalized = collapsed
        }
        return normalized
    }

    static func remoteSearchSuggestion(_ query: String) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .remote(query: query))
    }

    private static func displayURLText(for rawURL: String) -> String {
        guard let components = URLComponents(string: rawURL),
              var host = components.host else {
            return rawURL
        }

        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        host = host.lowercased()

        var result = host
        if let port = components.port {
            result += ":\(port)"
        }

        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            result += path
        } else if path == "/" {
            result += "/"
        }

        if let query = components.percentEncodedQuery, !query.isEmpty {
            result += "?\(query)"
        }

        if result.isEmpty { return rawURL }
        return result
    }
}

func browserOmnibarShouldReacquireFocusAfterEndEditing(
    desiredOmnibarFocus: Bool,
    nextResponderIsOtherTextField: Bool
) -> Bool {
    desiredOmnibarFocus && !nextResponderIsOtherTextField
}

func browserOmnibarShouldSelectAllOnFocusReassertion(
    selectionIntent: BrowserAddressBarFocusSelectionIntent
) -> Bool {
    selectionIntent.shouldSelectAll
}

/// Whether a completed single click that just moved first responder into the
/// omnibar should select the field's entire contents (Chrome/Safari/Arc parity),
/// instead of leaving the caret the field editor placed at the click point.
///
/// The first click on an unfocused omnibar showing a URL selects everything so
/// the user can immediately type a replacement. A subsequent click (the field is
/// already first responder, so `gainedFocusOnThisClick` is `false`) keeps the
/// caret placement from https://github.com/manaflow-ai/cmux/issues/5268. A drag
/// or a Shift-click expresses an explicit range, so select-all defers to it; a
/// double-click never reaches this path (the field routes multi-clicks straight
/// to the field editor for word/line selection, and its second click lands after
/// this click's `mouseUp`, so word selection wins).
///
/// - Parameters:
///   - gainedFocusOnThisClick: `true` when the field had no field editor at
///     `mouseDown`, i.e. this click is the one that moved focus into the omnibar.
///   - isShiftClick: `true` when Shift was held, extending an explicit selection.
///   - didDrag: `true` when the pointer moved far enough to build a drag selection.
/// - Returns: `true` only for an undragged, unmodified focus-gaining click.
func browserOmnibarFocusGainingClickShouldSelectAll(
    gainedFocusOnThisClick: Bool,
    isShiftClick: Bool,
    didDrag: Bool
) -> Bool {
    gainedFocusOnThisClick && !isShiftClick && !didDrag
}

