// The page view's input method ops on the Chromium Host's remote shim
// (plans/cmux-next/chromium-host-ops.json optional_exports). The remote shim sends
// each one ordered after the key frames written before it (remote_shim.mm, IsOrderedOp), and the
// host runs its shim's export of the same name, which calls the fork's remote-presentation IME:
// Chrome's ImeSetComposition, ImeCommitText, ImeFinishComposingText and
// ImeCancelComposition (content/common/render_widget_host_ns_view.mojom).

/// The shim's IME functions (``CEFShimLibrary/textInput``). Each is nil without the export: in
/// process, and with a host whose hello does not list it (the fork's IME exports not in its shim).
/// Offsets are UTF-16 units; text is UTF-16LE (``ChromiumHostTextInputBytes``). Each takes Swift
/// values; CEFShimLibrary+Bind.swift passes the bytes and their counts to the C export. Immutable,
/// part of the library that crosses from the loading thread.
nonisolated struct CEFShimTextInputOps {
    /// Browser, text bytes, clause bytes, the selection in the text (start, end), the field range
    /// the text replaces (start, end; -1 -1 none).
    let setComposition: ((Int32, [UInt8], [UInt8], Int32, Int32, Int32, Int32) -> Void)?
    /// Browser, text bytes, the field range it replaces (-1 -1: the composition, else the selection).
    let commitText: ((Int32, [UInt8], Int32, Int32) -> Void)?
    /// Browser: the composition's text stays and the composition ends.
    let finishComposing: (@convention(c) (Int32) -> Void)?
    /// Browser: the composition's text goes and the composition ends.
    let cancelComposition: (@convention(c) (Int32) -> Void)?

    /// The host's shim has every IME op: a hosted page takes input methods.
    var isComplete: Bool { setComposition != nil && commitText != nil && finishComposing != nil && cancelComposition != nil }
}

#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its text input.
extension CEFShimTextInputOps {
    /// Sends `op` for `browser` (a hosted page view's ``ChromiumHostPageView/textInputSink``).
    ///
    /// - Returns: False when the host's shim lacks the op, and for edit commands, which go with
    ///   Chrome's ExecuteEditCommand (task 047), not as IME ops.
    @discardableResult
    func send(_ op: ChromiumHostTextInputOp, browser: Int32) -> Bool {
        switch op {
        case let .setComposition(text, clauses, selection, replacement):
            guard let setComposition else { return false }
            let bytes = ChromiumHostTextInputBytes.utf16LE(text)
            let marks = ChromiumHostTextInputBytes.clauses(clauses)
            let replaced = Self.wireRange(replacement)
            setComposition(browser, bytes, marks, Int32(clamping: selection.lowerBound), Int32(clamping: selection.upperBound),
                           replaced.start, replaced.end)
        case let .commitText(text, replacement):
            guard let commitText else { return false }
            let bytes = ChromiumHostTextInputBytes.utf16LE(text)
            let replaced = Self.wireRange(replacement)
            commitText(browser, bytes, replaced.start, replaced.end)
        case .finishComposing:
            guard let finishComposing else { return false }
            finishComposing(browser)
        case .cancelComposition:
            guard let cancelComposition else { return false }
            cancelComposition(browser)
        case .keyCommands, .editCommand:
            return false
        }
        return true
    }

    /// A field range as the ops take it: -1 -1 for none.
    private static func wireRange(_ range: Range<Int>?) -> (start: Int32, end: Int32) {
        guard let range else { return (-1, -1) }
        return (Int32(clamping: range.lowerBound), Int32(clamping: range.upperBound))
    }
}
#endif
