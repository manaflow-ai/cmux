import AppKit
import SwiftUI

enum TerminalInput: Equatable, Sendable {
    case bytes(Data)
    case paste(String)
    case key(chord: String, repeat: Bool)
}

private let namedTerminalKeys: [UInt16: String] = [
    36: "enter", 76: "enter", 48: "tab", 53: "escape", 51: "backspace",
    117: "delete", 114: "insert", 115: "home", 119: "end", 116: "pageup",
    121: "pagedown", 123: "left", 124: "right", 125: "down", 126: "up",
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
    98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18",
    80: "f19", 90: "f20",
]

func terminalKeyChord(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String? = nil
) -> String? {
    let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
    guard !modifiers.contains(.command) else { return nil }
    let named = namedTerminalKeys[keyCode]
    let usesChordForText = modifiers.contains(.control) || modifiers.contains(.option)
    let key: String?
    if let named {
        key = named
    } else if usesChordForText,
        let charactersIgnoringModifiers,
        charactersIgnoringModifiers.count == 1
    {
        let character = charactersIgnoringModifiers.lowercased()
        let supported = "abcdefghijklmnopqrstuvwxyz0123456789 `\\[],=-.';/"
        key = supported.contains(character) ? (character == " " ? "space" : character) : nil
    } else {
        key = nil
    }
    guard let key else { return nil }
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("alt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    parts.append(key)
    return parts.joined(separator: "+")
}

final class TerminalTextView: NSTextView {
    private struct MarkedTextState {
        let text: NSAttributedString
        let anchor: Int
        let selection: NSRange
    }

    var submit: ((TerminalInput) -> Void)?
    var isInputReady = false
    var pasteboardText: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    }
    private var terminalMarkedRange = NSRange(location: NSNotFound, length: 0)
    private var terminalMarkedSelection = NSRange(location: NSNotFound, length: 0)
    private var terminalRows: [String] = []
    private var terminalRowOffsets: [Int] = []

    var terminalFrameText: String {
        guard let range = validMarkedRange else { return string }
        let frame = NSMutableString(string: string)
        frame.deleteCharacters(in: range)
        return frame as String
    }

    func configureForTerminal() {
        isEditable = false
        isSelectable = true
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        if let chord = terminalKeyChord(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) {
            guard isInputReady, let submit else {
                super.keyDown(with: event)
                return
            }
            submit(.key(chord: chord, repeat: event.isARepeat))
            return
        }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        interpretKeyEvents([event])
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text: String?
        switch insertString {
        case let value as NSAttributedString:
            text = value.string
        case let value as String:
            text = value
        default:
            text = nil
        }
        guard let text, !text.isEmpty else { return }
        guard isInputReady else { return }
        unmarkText()
        submit?(.bytes(Data(text.utf8)))
    }

    override func doCommand(by selector: Selector) {
        // Text input commands that are not committed text stay inside AppKit's
        // IME state instead of beeping or leaking a named key to the PTY.
    }

    override func hasMarkedText() -> Bool {
        validMarkedRange != nil
    }

    override func markedRange() -> NSRange {
        validMarkedRange ?? NSRange(location: NSNotFound, length: 0)
    }

    override func selectedRange() -> NSRange {
        hasMarkedText() ? terminalMarkedSelection : super.selectedRange()
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        _ = replacementRange
        let incoming: NSAttributedString
        switch string {
        case let value as NSAttributedString:
            incoming = value
        case let value as String:
            incoming = NSAttributedString(string: value)
        default:
            return
        }
        guard incoming.length > 0 else {
            unmarkText()
            return
        }
        guard let storage = textStorage else { return }

        let rendered = NSMutableAttributedString(attributedString: incoming)
        rendered.addAttributes(
            terminalMarkedTextAttributes,
            range: NSRange(location: 0, length: rendered.length)
        )
        let replacement: NSRange
        let anchor: Int
        if let range = validMarkedRange {
            replacement = range
            anchor = range.location
        } else {
            let selection = super.selectedRange()
            let (selectionEnd, overflow) = selection.location.addingReportingOverflow(
                max(0, selection.length)
            )
            let proposed =
                selection.location == NSNotFound || selection.location < 0 || overflow
                ? storage.length
                : selectionEnd
            anchor = min(max(0, proposed), storage.length)
            replacement = NSRange(location: anchor, length: 0)
        }
        storage.beginEditing()
        storage.replaceCharacters(in: replacement, with: rendered)
        storage.endEditing()

        terminalMarkedRange = NSRange(location: anchor, length: rendered.length)
        let relativeLocation = min(
            selectedRange.location == NSNotFound ? rendered.length : max(0, selectedRange.location),
            rendered.length
        )
        terminalMarkedSelection = NSRange(
            location: anchor + relativeLocation,
            length: min(max(0, selectedRange.length), rendered.length - relativeLocation)
        )
        super.setSelectedRange(terminalMarkedSelection)
        needsDisplay = true
    }

    override func unmarkText() {
        guard let marked = detachMarkedText() else { return }
        super.setSelectedRange(NSRange(location: marked.anchor, length: 0))
        needsDisplay = true
    }

    override func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .foregroundColor, .backgroundColor, .underlineStyle]
    }

    @discardableResult
    func applyTerminalFrame(
        _ next: String?,
        dirtyRows: [UInt16] = [],
        dirtyRowText: [UInt16: String] = [:],
        rowCount: Int = 0
    ) -> TerminalTextEdit? {
        let edit: TerminalTextEdit
        if let next {
            let current = terminalFrameText
            if current == next {
                terminalRows = next.isEmpty ? [""] : terminalRows(from: next)
                rebuildTerminalRowOffsets()
                return nil
            }
            guard let fullEdit = terminalTextEdit(from: current, to: next) else { return nil }
            edit = fullEdit
            terminalRows = terminalRows(from: next)
        } else if !terminalRows.isEmpty, !dirtyRows.isEmpty {
            guard let first = dirtyRows.min().map(Int.init),
                let last = dirtyRows.max().map(Int.init)
            else { return nil }
            let fullCoverage = dirtyRows.first == 0
                && dirtyRows.count == last + 1
                && rowCount == last + 1
            guard terminalRowOffsets.count == terminalRows.count + 1,
                fullCoverage || last < terminalRows.count
            else { return nil }
            guard dirtyRows.allSatisfy({ dirtyRowText[$0] != nil }) else { return nil }
            let changedRows = (first...last).map { dirtyRowText[UInt16($0)] ?? terminalRows[$0] }
            let start = fullCoverage ? 0 : terminalRowOffsets[first]
            let end = fullCoverage ? terminalRowOffsets.last! : terminalRowOffsets[last + 1]
            edit = TerminalTextEdit(
                range: NSRange(location: start, length: end - start),
                replacement: changedRows.joined()
            )
            if fullCoverage {
                terminalRows = changedRows
            } else {
                for (offset, row) in changedRows.enumerated() {
                    terminalRows[first + offset] = row
                }
            }
        } else {
            return nil
        }
        let marked = detachMarkedText()
        guard let storage = textStorage else { return nil }

        storage.beginEditing()
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        let replacementRange = NSRange(
            location: edit.range.location,
            length: edit.replacement.utf16.count
        )
        if replacementRange.length > 0 {
            storage.addAttributes(terminalTextAttributes, range: replacementRange)
        }
        storage.endEditing()

        if let marked {
            let remapped =
                remapTerminalSelection(
                    NSRange(location: marked.anchor, length: 0),
                    applying: edit
                )?.location ?? storage.length
            attachMarkedText(marked, at: min(max(0, remapped), storage.length))
        }
        rebuildTerminalRowOffsets()
        return edit
    }

    private func terminalRows(from text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0 + "\n" }
    }

    private func rebuildTerminalRowOffsets() {
        terminalRowOffsets = [0]
        for row in terminalRows {
            terminalRowOffsets.append(
                terminalRowOffsets[terminalRowOffsets.count - 1] + row.utf16.count
            )
        }
    }

    private var validMarkedRange: NSRange? {
        guard terminalMarkedRange.location != NSNotFound,
            terminalMarkedRange.location >= 0,
            terminalMarkedRange.length > 0,
            let storage = textStorage,
            terminalMarkedRange.location <= storage.length,
            terminalMarkedRange.length <= storage.length - terminalMarkedRange.location
        else { return nil }
        return terminalMarkedRange
    }

    private var terminalTextAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: textColor ?? NSColor.white,
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        ]
    }

    private var terminalMarkedTextAttributes: [NSAttributedString.Key: Any] {
        var attributes = terminalTextAttributes
        attributes[.backgroundColor] = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35)
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        return attributes
    }

    private func detachMarkedText() -> MarkedTextState? {
        guard let range = validMarkedRange, let storage = textStorage else {
            terminalMarkedRange = NSRange(location: NSNotFound, length: 0)
            terminalMarkedSelection = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let text = storage.attributedSubstring(from: range)
        let relativeLocation: Int
        if terminalMarkedSelection.location == NSNotFound
            || terminalMarkedSelection.location < range.location
        {
            relativeLocation = range.length
        } else {
            relativeLocation = min(
                terminalMarkedSelection.location - range.location,
                range.length
            )
        }
        let relativeSelection = NSRange(
            location: relativeLocation,
            length: min(
                max(0, terminalMarkedSelection.length),
                range.length - relativeLocation
            )
        )
        storage.beginEditing()
        storage.deleteCharacters(in: range)
        storage.endEditing()
        terminalMarkedRange = NSRange(location: NSNotFound, length: 0)
        terminalMarkedSelection = NSRange(location: NSNotFound, length: 0)
        return MarkedTextState(text: text, anchor: range.location, selection: relativeSelection)
    }

    private func attachMarkedText(_ marked: MarkedTextState, at anchor: Int) {
        guard let storage = textStorage else { return }
        storage.beginEditing()
        storage.insert(marked.text, at: anchor)
        storage.endEditing()
        terminalMarkedRange = NSRange(location: anchor, length: marked.text.length)
        terminalMarkedSelection = NSRange(
            location: anchor + marked.selection.location,
            length: marked.selection.length
        )
        super.setSelectedRange(terminalMarkedSelection)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
            modifiers == .command,
            event.charactersIgnoringModifiers?.lowercased() == "v",
            isTerminalFirstResponder
        {
            return submitPaste()
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        if item.action == #selector(paste(_:)) {
            return isInputReady && submit != nil && hasPasteboardText
        }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        _ = submitPaste()
    }

    private var hasPasteboardText: Bool {
        pasteboardText().map { !$0.isEmpty } ?? false
    }

    private var isTerminalFirstResponder: Bool {
        window?.firstResponder === self
    }

    @discardableResult
    private func submitPaste() -> Bool {
        guard isInputReady,
            let submit,
            let value = pasteboardText(),
            !value.isEmpty
        else { return false }
        submit(.paste(value))
        return true
    }
}

private final class TerminalContainerView: NSScrollView {
    var resized: ((TerminalGeometry) -> Void)?
    var terminalInset = NSSize(width: 8, height: 8)

    override func layout() {
        super.layout()
        resized?(
            terminalGeometry(
                width: contentSize.width,
                height: contentSize.height,
                horizontalInset: terminalInset.width * 2,
                verticalInset: terminalInset.height * 2
            ))
    }
}

struct TerminalView: NSViewRepresentable {
    let text: String?
    let dirtyRows: [UInt16]
    let dirtyRowText: [UInt16: String]
    let rowCount: Int
    let inputReady: Bool
    let submit: (TerminalInput) -> Void
    let resize: (TerminalGeometry) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TerminalContainerView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .black

        let terminal = TerminalTextView()
        terminal.configureForTerminal()
        terminal.isRichText = false
        terminal.allowsUndo = false
        terminal.drawsBackground = true
        terminal.backgroundColor = .black
        terminal.textColor = .white
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.textContainerInset = scroll.terminalInset
        terminal.isVerticallyResizable = true
        terminal.isHorizontallyResizable = true
        terminal.autoresizingMask = [.width]
        terminal.submit = submit
        terminal.isInputReady = inputReady
        scroll.documentView = terminal
        scroll.resized = resize
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let scroll = scroll as? TerminalContainerView {
            scroll.resized = resize
        }
        guard let terminal = scroll.documentView as? TerminalTextView else { return }
        terminal.submit = submit
        terminal.isInputReady = inputReady
        if !inputReady {
            terminal.unmarkText()
        }
        let isComposing = terminal.hasMarkedText()
        let selection = isComposing ? [] : terminal.selectedRanges
        let visible = scroll.documentVisibleRect
        let followedBottom = visible.maxY >= terminal.bounds.maxY - 24
        // applyTerminalFrame computes the cached-frame edit once. Keeping the
        // equality check there avoids a second full-frame scan on every update.
        guard let edit = terminal.applyTerminalFrame(
            text,
            dirtyRows: dirtyRows,
            dirtyRowText: dirtyRowText,
            rowCount: rowCount
        ) else { return }
        if !isComposing {
            terminal.selectedRanges = terminalSelections(
                preserving: selection,
                applying: edit,
                utf16Length: terminal.string.utf16.count
            )
        }
        if followedBottom {
            terminal.scrollToEndOfDocument(nil)
        } else {
            terminal.scroll(visible.origin)
        }
    }
}

struct TerminalTextEdit: Equatable {
    let range: NSRange
    let replacement: String
}

func terminalTextEdit(from current: String, to next: String) -> TerminalTextEdit? {
    guard current != next else { return nil }
    let currentScalars = current.unicodeScalars
    let nextScalars = next.unicodeScalars
    var currentStart = currentScalars.startIndex
    var nextStart = nextScalars.startIndex
    while currentStart != currentScalars.endIndex,
        nextStart != nextScalars.endIndex,
        currentScalars[currentStart] == nextScalars[nextStart]
    {
        currentScalars.formIndex(after: &currentStart)
        nextScalars.formIndex(after: &nextStart)
    }

    var currentEnd = currentScalars.endIndex
    var nextEnd = nextScalars.endIndex
    while currentEnd != currentStart, nextEnd != nextStart {
        let priorCurrent = currentScalars.index(before: currentEnd)
        let priorNext = nextScalars.index(before: nextEnd)
        guard currentScalars[priorCurrent] == nextScalars[priorNext] else { break }
        currentEnd = priorCurrent
        nextEnd = priorNext
    }

    let location = currentStart.utf16Offset(in: current)
    let end = currentEnd.utf16Offset(in: current)
    return TerminalTextEdit(
        range: NSRange(location: location, length: end - location),
        replacement: String(next[nextStart..<nextEnd])
    )
}

private func remapTerminalSelection(
    _ range: NSRange,
    applying edit: TerminalTextEdit
) -> NSRange? {
    guard range.location != NSNotFound,
        range.location >= 0,
        range.length >= 0,
        edit.range.location != NSNotFound,
        edit.range.location >= 0,
        edit.range.length >= 0
    else {
        return nil
    }
    let (rangeEnd, rangeOverflow) = range.location.addingReportingOverflow(range.length)
    let (editEnd, editOverflow) = edit.range.location.addingReportingOverflow(edit.range.length)
    let replacementLength = edit.replacement.utf16.count
    let (replacementEnd, replacementOverflow) =
        edit.range.location.addingReportingOverflow(replacementLength)
    let (delta, deltaOverflow) = replacementLength.subtractingReportingOverflow(edit.range.length)
    guard !rangeOverflow, !editOverflow, !replacementOverflow, !deltaOverflow else { return nil }

    func shifted(_ position: Int) -> Int? {
        let (shifted, overflow) = position.addingReportingOverflow(delta)
        return overflow ? nil : shifted
    }

    if range.length == 0 {
        let location: Int
        if range.location < edit.range.location {
            location = range.location
        } else if range.location >= editEnd {
            guard let shifted = shifted(range.location) else { return nil }
            location = shifted
        } else {
            location = replacementEnd
        }
        return NSRange(location: location, length: 0)
    }

    if range.location >= edit.range.location, rangeEnd <= editEnd {
        return NSRange(location: edit.range.location, length: 0)
    }

    let start: Int
    if range.location < edit.range.location {
        start = range.location
    } else if range.location >= editEnd {
        guard let shifted = shifted(range.location) else { return nil }
        start = shifted
    } else {
        start = edit.range.location
    }

    let end: Int
    if rangeEnd <= edit.range.location {
        end = rangeEnd
    } else if rangeEnd >= editEnd {
        guard let shifted = shifted(rangeEnd) else { return nil }
        end = shifted
    } else {
        end = replacementEnd
    }
    guard end >= start else { return nil }
    return NSRange(location: start, length: end - start)
}

func terminalSelections(
    preserving selections: [NSValue],
    applying edit: TerminalTextEdit? = nil,
    utf16Length: Int
) -> [NSValue] {
    let boundedLength = max(0, utf16Length)
    let valid = selections.compactMap { selection -> NSValue? in
        let original = selection.rangeValue
        let range: NSRange
        if let edit {
            guard let remapped = remapTerminalSelection(original, applying: edit) else {
                return nil
            }
            range = remapped
        } else {
            range = original
        }
        guard range.location != NSNotFound,
            range.location >= 0,
            range.location <= boundedLength,
            range.length >= 0
        else {
            return nil
        }
        return NSValue(
            range: NSRange(
                location: range.location,
                length: min(range.length, boundedLength - range.location)
            ))
    }
    if !valid.isEmpty {
        return valid
    }
    return [NSValue(range: NSRange(location: boundedLength, length: 0))]
}
