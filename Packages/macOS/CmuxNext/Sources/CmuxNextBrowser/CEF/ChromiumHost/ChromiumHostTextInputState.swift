#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
import CoreGraphics

/// The focused field's text input state as the Chromium Host pushes it,
/// TEXT_INPUT_STATE (plans/cmux-next/chrome-parity/p01-process.md 3.3, task
/// 044): the host sends one after each change, ahead of any question an input
/// method asks, so cmux answers every `NSTextInputClient` query from this value
/// and never asks the host and waits. Chrome keeps the same three pieces in its
/// browser process (`content/browser/renderer_host/text_input_manager.h`:
/// TextInputState, CompositionRangeInfo, TextSelection) and still makes 2 sync
/// calls when they miss; cmux makes none.
///
/// Offsets are UTF-16 code units in the field. Rects are page-view points with
/// a top-left origin, the page's own coordinates (``ChromiumHostPageView``'s
/// wire points).
nonisolated struct ChromiumHostTextInputState: Equatable, Sendable {
    /// `ui::TextInputType` (ui/base/ime/text_input_type.h); kinds this side
    /// does not name keep their raw value.
    struct InputType: RawRepresentable, Hashable, Sendable {
        var rawValue: Int32

        /// No text field focused (TEXT_INPUT_TYPE_NONE).
        static let noField = InputType(rawValue: 0)
        static let text = InputType(rawValue: 1)
        static let password = InputType(rawValue: 2)
        static let search = InputType(rawValue: 3)
        static let email = InputType(rawValue: 4)
        static let number = InputType(rawValue: 5)
        static let telephone = InputType(rawValue: 6)
        static let url = InputType(rawValue: 7)
        static let textArea = InputType(rawValue: 14)
        static let contentEditable = InputType(rawValue: 15)

        /// Whether an input method may compose here. Chrome gives no input
        /// context to a page with no text field focused or to a password field
        /// (`-[RenderWidgetHostViewCocoa inputContext]`), so plain key
        /// bindings still type and no input method sees a password.
        var takesInputMethod: Bool { self != .noField && self != .password }
    }

    var type: InputType = .noField
    /// `ui::TextInputFlags` bits, as the host sends them.
    var flags: UInt32 = 0
    /// The selection (a caret is empty); nil with no field focused.
    var selection: Range<Int>?
    /// The text around the selection: the selection and about 100 code units
    /// on each side (Chrome's kExtraCharsBeforeAndAfterSelection).
    private(set) var text: [UInt16] = []
    /// Where ``text`` starts in the field.
    var textOffset = 0
    /// The page's composition; nil while none.
    var composition: Range<Int>?
    /// One rect per code unit of ``composition`` (CompositionRangeInfo's
    /// character bounds).
    var compositionRects: [CGRect] = []
    /// The caret, or the first line of a non-empty selection (Chrome's
    /// SelectionRegion caret_rect and first_selection_rect).
    var caretRect: CGRect = .zero

    init(type: InputType = .noField, flags: UInt32 = 0, selection: Range<Int>? = nil, text: String = "",
         textOffset: Int = 0, composition: Range<Int>? = nil, compositionRects: [CGRect] = [],
         caretRect: CGRect = .zero) {
        self.type = type
        self.flags = flags
        self.selection = selection
        self.text = Array(text.utf16)
        self.textOffset = textOffset
        self.composition = composition
        self.compositionRects = compositionRects
        self.caretRect = caretRect
    }

    /// The pushed composition when its rects match it, as Chrome requires
    /// (one rect per character); nil otherwise.
    private var measuredComposition: Range<Int>? {
        guard let composition, !composition.isEmpty, compositionRects.count == composition.count else { return nil }
        return composition
    }

    /// `firstRectForCharacterRange` from pushed rects only: the rect of
    /// `requested` up to its first line break, and the range that rect covers.
    /// Chrome's cached answer, one for one
    /// (`RenderWidgetHostViewMac::GetCachedFirstRectForCharacterRange` and
    /// `GetFirstRectForCompositionRange`,
    /// content/browser/renderer_host/render_widget_host_view_mac.mm). Nil
    /// where Chrome would ask the renderer: cmux never does.
    func firstRect(for requested: Range<Int>) -> (rect: CGRect, actual: Range<Int>)? {
        if requested.isEmpty, let selection, selection == requested {
            return (caretRect, requested)
        }
        guard let composition, !composition.isEmpty else {
            guard let selection, requested.lowerBound >= selection.lowerBound,
                  requested.upperBound <= selection.upperBound else { return nil }
            return (caretRect, selection)
        }
        guard let measured = measuredComposition, requested.lowerBound >= measured.lowerBound,
              requested.upperBound <= measured.upperBound else { return nil }
        let start = requested.lowerBound - composition.lowerBound
        let local = start..<(start + requested.count)
        let found = firstCompositionRect(local)
        return (found.rect, (found.actual.lowerBound + composition.lowerBound)..<(found.actual.upperBound + composition.lowerBound))
    }

    /// `range` is inside the composition (offsets from its start), with one rect per code unit.
    private func firstCompositionRect(_ range: Range<Int>) -> (rect: CGRect, actual: Range<Int>) {
        let rects = compositionRects
        if range.isEmpty {
            // A zero-width rect at the caret: after the last character, or before the one at the caret.
            if range.lowerBound == rects.count {
                let last = rects[range.lowerBound - 1]
                return (CGRect(x: last.maxX, y: last.minY, width: 0, height: last.height), range)
            }
            let next = rects[range.lowerBound]
            return (CGRect(x: next.minX, y: next.minY, width: 0, height: next.height), range)
        }
        let end = lineBreak(in: range) ?? range.upperBound
        var rect = rects[range.lowerBound]
        for index in stride(from: range.lowerBound + 1, to: end, by: 1) {
            rect = rect.union(rects[index])
        }
        return (rect, range.lowerBound..<end)
    }

    /// The first character of `range` on a later line than the first: one
    /// whose top is below the highest top plus 3/4 of the tallest character
    /// (Chrome's `GetLineBreakIndex`: rects alone cannot show a line break).
    private func lineBreak(in range: Range<Int>) -> Int? {
        let rects = compositionRects
        guard !range.isEmpty, range.lowerBound < rects.count else { return nil }
        let end = min(rects.count, range.upperBound)
        var tallest: CGFloat = 0
        var highest = CGFloat.greatestFiniteMagnitude
        for index in range.lowerBound..<end {
            tallest = max(tallest, rects[index].height)
            highest = min(highest, rects[index].minY)
        }
        let threshold = highest + tallest * 3 / 4
        return (range.lowerBound..<end).first { rects[$0].minY > threshold }
    }

    /// `characterIndexForPoint` from pushed rects only: the composition
    /// character under `point` (page-view points, top-left origin); nil off
    /// every one. Chrome asks the renderer here (`SyncGetCharacterIndexAtPoint`);
    /// the input methods that ask (a click in the marked text) ask about the
    /// composition, whose rects the host pushed.
    func characterIndex(at point: CGPoint) -> Int? {
        guard let measured = measuredComposition else { return nil }
        return compositionRects.firstIndex { $0.contains(point) }.map { measured.lowerBound + $0 }
    }

    /// `attributedSubstringForProposedRange` from pushed text only: the part
    /// of `requested` that `markedText` (while it has a pushed place) or the
    /// pushed text holds, and the range it covers; nil when they do not meet.
    /// Chrome's own answer (`-[RenderWidgetHostViewCocoa
    /// attributedSubstringForProposedRange:actualRange:]`).
    func substring(of requested: Range<Int>, markedText: [UInt16]) -> (text: String, actual: Range<Int>)? {
        let composing = composition.map { !$0.isEmpty && !markedText.isEmpty } ?? false
        let source = composing ? markedText : text
        let start = composing ? (composition?.lowerBound ?? 0) : textOffset
        let lower = max(start, requested.lowerBound)
        let upper = min(start + source.count, requested.upperBound)
        guard lower <= upper else { return nil }
        return (String(decoding: source[(lower - start)..<(upper - start)], as: UTF16.self), lower..<upper)
    }
}

/// One underlined clause of a composition (Chrome's `ui::ImeTextSpan` of type
/// kComposition): the selected clause is thick.
nonisolated struct ChromiumHostCompositionClause: Equatable, Sendable {
    /// Offsets in the marked text.
    var range: Range<Int>
    var thick: Bool
    /// The underline color as 0xAARRGGBB; black unless the input method named one.
    var color: UInt32 = 0xFF00_0000
}

/// What the page's text input sends the host besides key frames. Each one
/// rides the one ordered input stream after the key frames written before it
/// (task 092), so a commit never passes the key that made it. The host runs
/// the fork's IME exports (task 170): `ime_set_composition`,
/// `ime_commit_text`, `ime_finish_composing`, `ime_cancel`.
nonisolated enum ChromiumHostTextInputOp: Equatable, Sendable {
    /// Shows `text` as the composition, its selection at `selection` (offsets
    /// in `text`), replacing `replacement` of the field first when set.
    case setComposition(text: String, clauses: [ChromiumHostCompositionClause], selection: Range<Int>,
                        replacement: Range<Int>?)
    /// Inserts `text` in place of the composition, or of `replacement` when set.
    case commitText(String, replacement: Range<Int>?)
    /// Keeps the composition's text as typed and ends it.
    case finishComposing
    /// Removes the composition's text and ends it.
    case cancelComposition
    /// The edit commands AppKit's key bindings chose for the key frame that
    /// follows ("DeleteBackward", "MoveLeft"), as Chrome sends them with the
    /// key down (`ForwardKeyboardEventWithCommands`).
    case keyCommands([String])
    /// An edit command with no key: an input method or a service sent it.
    case editCommand(String)
}
#endif
