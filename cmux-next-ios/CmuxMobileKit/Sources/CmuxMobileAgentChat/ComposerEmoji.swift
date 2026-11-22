#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// The composer's emoji shortcodes, live: what `EmojiShortcodes` decides, applied to the
/// field's UITextView (ChatComposerField) and drawn as the suggestion list over the composer
/// (ChatComposer). Every conversion goes through the text view's own `replace(_:withText:)` in
/// its own undo group, a run loop turn after the keystroke or paste that caused it, so one
/// undo brings back exactly what was typed or pasted (`:plead`, `:pleading_face:`).
@MainActor @Observable
final class ComposerEmoji {
    /// The list's rows; empty when it is closed.
    private(set) var rows: [EmojiMatch] = []
    /// The row Tab, Return or a tap writes (arrows move it).
    var highlighted = 0
    /// The token the rows are for (`:plead`), shown nowhere but kept for accept.
    @ObservationIgnored private(set) var trigger: EmojiTrigger?
    @ObservationIgnored weak var textView: UITextView?
    /// Esc closed the list on this text: it stays closed until the text changes.
    @ObservationIgnored private var dismissedText: String?
    /// The field's binding, set after an edit made here.
    @ObservationIgnored var onTextChange: (@MainActor (String) -> Void)?

    var isOpen: Bool { !rows.isEmpty }

    /// Reads the trigger at the caret and lists its rows. Nothing while text is being composed
    /// (marked text, an input method's candidate) or a range is selected.
    func refresh(_ view: UITextView) {
        textView = view
        let text = view.text ?? ""
        guard view.markedTextRange == nil, view.selectedRange.length == 0, dismissedText != text,
              let trigger = EmojiShortcodes.trigger(in: text, caret: view.selectedRange.location) else {
            close()
            return
        }
        let rows = EmojiShortcodes.matches(trigger, in: .bundled, prefs: EmojiPrefsStore.prefs)
        if trigger.token != self.trigger?.token || highlighted >= rows.count { highlighted = 0 }
        self.trigger = trigger
        if self.rows != rows { self.rows = rows }
    }

    /// After an edit. `typedColon`: the edit was the person typing `:` (not an undo, not a paste),
    /// which may close a known `:code:`.
    func textDidChange(_ view: UITextView, typedColon: Bool) {
        let text = view.text ?? ""
        if dismissedText != text { dismissedText = nil }
        // The table reads the first time a `:` is typed, off the main thread, so the list's first
        // rows two letters later find it parsed.
        if typedColon { Task.detached(priority: .userInitiated) { _ = EmojiShortcodeTable.bundled } }
        if typedColon, view.markedTextRange == nil,
           let edit = EmojiShortcodes.closingColon(in: text, caret: view.selectedRange.location, table: .bundled,
                                                   tone: EmojiPrefsStore.prefs.tone) {
            later(edit, in: view, unless: text)
        }
        refresh(view)
    }

    /// A paste's `:code:`s become emoji in one step after the paste (undo restores it as pasted).
    func didPaste(_ range: NSRange, in view: UITextView) {
        let text = view.text ?? ""
        guard view.markedTextRange == nil, NSMaxRange(range) <= (text as NSString).length else { return }
        let pasted = (text as NSString).substring(with: range)
        guard let converted = EmojiShortcodes.convertingPaste(pasted, table: .bundled, tone: EmojiPrefsStore.prefs.tone) else { return }
        var edit = EmojiEdit(range: range, replacement: converted.text, caret: range.location + converted.text.utf16.count)
        edit.rememberTone = converted.rememberTone
        later(edit, in: view, unless: text)
    }

    /// Writes the highlighted row (or `index`): the glyph in the remembered tone and a space.
    @discardableResult
    func accept(_ index: Int? = nil) -> Bool {
        let index = index ?? highlighted
        guard let view = textView, let trigger, rows.indices.contains(index) else { return false }
        apply(EmojiShortcodes.accept(rows[index], for: trigger, in: view.text ?? "", table: .bundled, tone: EmojiPrefsStore.prefs.tone), in: view)
        return true
    }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        highlighted = (highlighted + step + rows.count) % rows.count
    }

    /// Esc: closed for this text.
    func dismiss() {
        dismissedText = textView?.text
        close()
    }

    func close() {
        trigger = nil
        if !rows.isEmpty { rows = [] }
        highlighted = 0
    }

    /// The edit one run loop turn later, its own undo step, if the text is still `unless`.
    private func later(_ edit: EmojiEdit, in view: UITextView, unless text: String) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view, view.text == text, view.markedTextRange == nil else { return }
            self.apply(edit, in: view)
        }
    }

    private func apply(_ edit: EmojiEdit, in view: UITextView) {
        let begin = view.beginningOfDocument
        guard let start = view.position(from: begin, offset: edit.range.location),
              let end = view.position(from: start, offset: edit.range.length),
              let range = view.textRange(from: start, to: end) else { return }
        view.undoManager?.beginUndoGrouping()
        view.replace(range, withText: edit.replacement)
        view.undoManager?.endUndoGrouping()
        if let caret = view.position(from: begin, offset: edit.caret) {
            view.selectedTextRange = view.textRange(from: caret, to: caret)
        }
        if let tone = edit.rememberTone { EmojiPrefsStore.prefs.tone = tone }
        if let picked = edit.picked {
            EmojiPrefsStore.prefs = EmojiPrefsStore.prefs.recording(picked, now: Date().timeIntervalSince1970)
        }
        onTextChange?(view.text ?? "")
        close()
        refresh(view)
    }
}

/// The remembered tone and recent picks: this phone's own UI memory, never sent anywhere.
@MainActor
enum EmojiPrefsStore {
    static let key = "cmux.composer.emojiPrefs"
    private static var cached: EmojiPrefs?

    static var prefs: EmojiPrefs {
        get {
            if let cached { return cached }
            let loaded = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(EmojiPrefs.self, from: $0) } ?? EmojiPrefs()
            cached = loaded
            return loaded
        }
        set {
            cached = newValue
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
        }
    }
}

/// The emoji list over the composer, drawn like the `@` and `/` lists (glass card, 44 pt rows,
/// the press fill): the glyph, then `:code:` with the typed letters in bold. The highlighted row
/// (what Tab or Return writes) carries the selected fill.
struct EmojiSuggestionList: View {
    let emoji: ComposerEmoji

    static let accessibilityIdentifier = "chat.composer.emoji"

    /// The looks compared for the PR (DEBUG `-cmux-mobile-emoji-look chips|grid`); the list ships.
    enum Look: String { case list, chips, grid }

    static var look: Look {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-cmux-mobile-emoji-look"), arguments.indices.contains(index + 1),
           let look = Look(rawValue: arguments[index + 1]) { return look }
        #endif
        return .list
    }

    var body: some View {
        switch Self.look {
        case .list: list
        case .chips: chips
        case .grid: grid
        }
    }

    /// A horizontal strip of `glyph :code:` capsules, one row tall (QuickType's place).
    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                // visible-only: at most EmojiShortcodes.shown (6) rows.
                ForEach(Array(emoji.rows.enumerated()), id: \.element.id) { index, row in
                    Button { emoji.accept(index) } label: {
                        HStack(spacing: 6) {
                            Text(row.emoji).font(.title3)
                            Self.code(row).font(.footnote.monospaced()).lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(index == emoji.highlighted ? Color.cmuxMobileFillSelected : Color.cmuxMobileFill, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.cmuxPressFillCapsule)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        .padding(.horizontal, 12)
    }

    /// Big glyph tiles in one row, the highlighted one's `:code:` under them.
    private var grid: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Array(emoji.rows.enumerated()), id: \.element.id) { index, row in
                    Button { emoji.accept(index) } label: {
                        Text(row.emoji)
                            .font(.largeTitle)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(index == emoji.highlighted ? Color.cmuxMobileFillSelected : .clear,
                                        in: .rect(cornerRadius: 12, style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.cmuxPressFill)
                    .accessibilityLabel(Text(verbatim: "\(row.emoji) :\(row.code):"))
                }
            }
            if emoji.rows.indices.contains(emoji.highlighted) {
                Self.code(emoji.rows[emoji.highlighted]).font(.footnote.monospaced()).lineLimit(1)
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        .padding(.horizontal, 12)
    }

    /// Rows like the `@` and `/` lists: glyph, `:code:`.
    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(emoji.rows.enumerated()), id: \.element.id) { index, row in
                Button {
                    emoji.accept(index)
                } label: {
                    HStack(spacing: 10) {
                        Text(row.emoji)
                            .font(.title3)
                            .frame(width: 28)
                        Self.code(row)
                            .font(.body.monospaced())
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: SlashSuggestionsBound.minRowHeight)
                    .background(index == emoji.highlighted ? Color.cmuxMobileFillSelected : .clear)
                    .contentShape(.rect)
                }
                .buttonStyle(.cmuxPressFill)
                .accessibilityLabel(Text(verbatim: "\(row.emoji) :\(row.code):"))
                .accessibilityAddTraits(index == emoji.highlighted ? .isSelected : [])
            }
        }
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier(Self.accessibilityIdentifier)
        .padding(.horizontal, 12)
    }

    /// `:code:`, the letters the query matched in bold, the rest secondary.
    static func code(_ row: EmojiMatch) -> Text {
        let code = row.code as NSString
        guard row.matched.length > 0, NSMaxRange(row.matched) <= code.length else {
            return Text(verbatim: ":\(row.code):").foregroundStyle(.secondary)
        }
        let head = code.substring(to: row.matched.location)
        let hit = code.substring(with: row.matched)
        let tail = code.substring(from: NSMaxRange(row.matched))
        return Text(verbatim: ":\(head)").foregroundStyle(.secondary)
            + Text(verbatim: hit).bold().foregroundStyle(.primary)
            + Text(verbatim: "\(tail):").foregroundStyle(.secondary)
    }
}
#endif
