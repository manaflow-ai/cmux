import Foundation
import Testing
@testable import CmuxNextBrowser

/// A text field that behaves like `NSTextView` for the omnibar: typing
/// replaces the selection, the applier writes it. Counts writes made while
/// marked text is pending (must stay 0).
@MainActor final class FakeOmnibarField: OmnibarFieldSurface {
    var text = ""
    var selection = NSRange(location: 0, length: 0)
    var marked: NSRange?
    var editorActive = false
    var style: OmnibarPresentation.Style = .plain
    private(set) var writesWhileMarked = 0

    var isFieldEditorActive: Bool { editorActive }
    var currentText: String { text }
    var currentSelection: NSRange { selection }
    var hasMarkedText: Bool { marked != nil }

    func write(_ text: String, style: OmnibarPresentation.Style) {
        if marked != nil { writesWhileMarked += 1 }
        self.text = text
        self.style = style
        selection = NSRange(location: (text as NSString).length, length: 0)
    }

    func select(_ range: NSRange) {
        if marked != nil { writesWhileMarked += 1 }
        selection = range
    }

    var snapshot: OmnibarInput.Field { .init(text: text, selection: selection, marked: marked) }

    /// Replaces the selection (or the marked range) with `string`.
    func insert(_ string: String) {
        let target = marked ?? selection
        text = (text as NSString).replacingCharacters(in: target, with: string)
        selection = NSRange(location: target.location + (string as NSString).length, length: 0)
        marked = nil
    }

    func deleteBackward() {
        var target = selection
        if target.length == 0 {
            guard target.location > 0 else { return }
            target = NSRange(location: target.location - 1, length: 1)
        }
        text = (text as NSString).replacingCharacters(in: target, with: "")
        selection = NSRange(location: target.location, length: 0)
    }

    /// IME: replaces the marked range (or selection) with marked `string`.
    func setMarked(_ string: String) {
        let target = marked ?? selection
        text = (text as NSString).replacingCharacters(in: target, with: string)
        let length = (string as NSString).length
        marked = length == 0 ? nil : NSRange(location: target.location, length: length)
        selection = NSRange(location: target.location + length, length: 0)
    }
}

@MainActor final class FakeOmnibarPopup: OmnibarPopupSurface {
    private(set) var rows: [BrowserSuggestion] = []
    private(set) var highlightedRows: Set<Int> = []

    func showRows(_ rows: [BrowserSuggestion], highlighted: Int?) {
        self.rows = rows
        highlightedRows = highlighted.map { [$0] } ?? []
    }

    func highlightRow(_ row: Int?) { highlightedRows = row.map { [$0] } ?? [] }

    func dismissRows() {
        rows = []
        highlightedRows = []
    }
}

/// Drives the pure reducer and the real effect applier against fake
/// surfaces, checking the invariants after every step.
@MainActor final class OmnibarSim {
    static let page = URL(string: "https://github.com/manaflow-ai/cmux")!
    static let history = [
        "https://github.com/", "https://gist.github.com/", "https://example.com/docs", "https://nihon.example/",
    ]

    var state: OmnibarState
    let field = FakeOmnibarField()
    let popup = FakeOmnibarPopup()
    let applier: OmnibarEffectApplier
    var resolver = OmniboxResolver()
    var effects: [OmnibarEffect] = []
    /// Queries asked for and not yet answered, oldest first.
    var queries: [(generation: UInt64, text: String)] = []
    var historyURLs = OmnibarSim.history
    /// Recent inputs, printed with the first broken invariant.
    private(set) var log: [String] = []
    private(set) var failed = false

    init(page: URL? = OmnibarSim.page) {
        state = OmnibarState(pageURL: page)
        applier = OmnibarEffectApplier(field: field, popup: popup)
        applier.apply(OmnibarPresentation(state))
    }

    var ended: [OmnibarEndReason] {
        effects.compactMap { if case .ended(let reason) = $0 { reason } else { nil } }
    }

    @discardableResult
    func send(_ input: OmnibarInput) -> Bool {
        log.append("\(input) field=\(field.text.debugDescription) sel=\(field.selection) marked=\(String(describing: field.marked))")
        if log.count > 16 { log.removeFirst() }
        let transition = OmnibarReducer.reduce(state, input, resolver: resolver)
        state = transition.state
        applier.apply(OmnibarPresentation(state))
        effects += transition.effects
        for effect in transition.effects {
            switch effect {
            case .query(let generation, let text): queries.append((generation, text))
            case .keywordInput(_, let text, let generation): queries.append((generation, text))
            case .cancelQuery: queries.removeAll()
            case .began, .ended, .beep, .deleteSuggestion, .typedNavigation, .copyAnswer, .keywordStarted, .keywordEnded: break
            }
        }
        checkInvariants()
        return transition.handled
    }

    func rows(for text: String) -> [BrowserSuggestion] {
        let engine = OmniboxSuggestionEngine(resolver: resolver)
        var rows = engine.primarySuggestion(for: text.trimmingCharacters(in: .whitespaces)).map { [$0] } ?? []
        let lowered = text.lowercased()
        for url in historyURLs where url.lowercased().contains(lowered) {
            rows.append(BrowserSuggestion(kind: .history, title: "Page", detail: url, url: URL(string: url)!, score: 700))
        }
        return rows
    }

    // MARK: User actions

    func focus(_ source: OmnibarInput.FocusSource = .keyboard) {
        field.editorActive = true
        send(.focusGained(source))
    }

    func blur() {
        field.marked = nil
        field.editorActive = false
        send(.focusLost)
    }

    /// Types `text` one key at a time; `settle` answers each query before
    /// the next key, as a fast engine does.
    func type(_ text: String, settle: Bool = true) {
        for character in text {
            field.insert(String(character))
            send(.fieldChanged(field.snapshot, .insert))
            if settle { answer() }
        }
    }

    func backspace() {
        field.deleteBackward()
        send(.fieldChanged(field.snapshot, .delete))
    }

    func paste(_ text: String) {
        field.insert(text)
        send(.fieldChanged(field.snapshot, .paste))
    }

    func compose(_ marked: String) {
        field.setMarked(marked)
        send(.fieldChanged(field.snapshot, .insert))
    }

    func commitComposition(_ text: String) {
        field.insert(text)
        send(.fieldChanged(field.snapshot, .insert))
    }

    func moveSelection(to range: NSRange) {
        field.selection = range
        send(.fieldChanged(field.snapshot, nil))
    }

    @discardableResult
    func key(_ key: OmnibarInput.Key) -> Bool { send(.key(key)) }

    /// Answers the newest query (drops the older ones, as the controller
    /// cancels them).
    func answer() {
        guard let latest = queries.last else { return }
        queries.removeAll()
        send(.suggestions(generation: latest.generation, rows: rows(for: latest.text)))
    }

    /// A click in the field: the field editor tracks the click to
    /// `selection` (in the text shown at the press), then mouse-up. AppKit
    /// makes the field first responder before it forwards the press
    /// (`focusFirst`); the machine also accepts the press first.
    func click(count: Int = 1, word: NSRange? = nil, selecting selection: NSRange, focusFirst: Bool = true) {
        if focusFirst, !field.editorActive { focus(.mouse) }
        send(.fieldMouseDown(clickCount: count, word: word))
        if !field.editorActive { focus(.mouse) }
        moveSelection(to: selection)
        send(.fieldMouseUp)
    }

    /// A right-click. `selecting` is what the field editor selects on its
    /// own (a word under the pointer). Returns the selection the context
    /// menu opens with (menus open on the press on macOS).
    @discardableResult
    func rightClick(selecting selection: NSRange? = nil) -> NSRange {
        if !field.editorActive { focus(.mouse) }
        send(.fieldMouseDown(clickCount: 1, button: .right))
        if let selection { moveSelection(to: selection) }
        let atMenu = field.selection
        send(.fieldMouseUp)
        return atMenu
    }

    /// The text Copy puts on the pasteboard now.
    var copied: OmnibarCopy? { OmnibarReducer.copyContent(of: state, resolver: resolver) }

    // MARK: Invariants

    func checkInvariants(sourceLocation: SourceLocation = #_sourceLocation) {
        guard !failed else { return }
        defer {
            if !failed, !invariantsHold {
                failed = true
                Issue.record("invariant broken after:\n\(log.joined(separator: "\n"))\nstate: \(state)", sourceLocation: sourceLocation)
            }
        }
        #expect(field.text == state.fieldText, "field text == model text", sourceLocation: sourceLocation)
        let length = (state.fieldText as NSString).length
        if state.hasFocus {
            let selection = state.edit.selection
            #expect(selection.location >= 0 && selection.location + selection.length <= length, "caret within bounds", sourceLocation: sourceLocation)
            if field.editorActive, field.marked == nil {
                #expect(field.selection == selection, "field selection == model selection", sourceLocation: sourceLocation)
            }
        }
        #expect(popup.highlightedRows.count <= 1, "at most one highlighted row", sourceLocation: sourceLocation)
        #expect(popup.highlightedRows.allSatisfy { popup.rows.indices.contains($0) }, sourceLocation: sourceLocation)
        if state.phase != .editing {
            #expect(popup.rows.isEmpty, "suggestions closed when not editing", sourceLocation: sourceLocation)
            #expect(state.popup.rows.isEmpty, sourceLocation: sourceLocation)
        }
        if state.isComposing { #expect(state.edit.inlineCompletion.isEmpty, "no completion while composing", sourceLocation: sourceLocation) }
        #expect(field.writesWhileMarked == 0, "no field write while marked text is pending", sourceLocation: sourceLocation)
    }

    private var invariantsHold: Bool {
        guard field.text == state.fieldText, field.writesWhileMarked == 0, popup.highlightedRows.count <= 1 else { return false }
        let length = (state.fieldText as NSString).length
        if state.hasFocus {
            let selection = state.edit.selection
            if selection.location < 0 || selection.location + selection.length > length { return false }
            if field.editorActive, field.marked == nil, field.selection != selection { return false }
        }
        if state.phase != .editing, !popup.rows.isEmpty { return false }
        return true
    }
}
