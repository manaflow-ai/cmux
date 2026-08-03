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
    var submit: ((TerminalInput) -> Void)?
    var isInputReady = false
    var pasteboardText: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    }

    func configureForTerminal() {
        isEditable = false
        isSelectable = true
    }

    override func keyDown(with event: NSEvent) {
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
        submit?(.bytes(Data(text.utf8)))
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
    let text: String
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
        guard let terminal = scroll.documentView as? TerminalTextView else { return }
        terminal.submit = submit
        terminal.isInputReady = inputReady
        guard terminal.string != text else { return }
        let selection = terminal.selectedRanges
        let visible = scroll.documentVisibleRect
        let followedBottom = visible.maxY >= terminal.bounds.maxY - 24
        let edit = terminalTextEdit(from: terminal.string, to: text)
        if let edit, let storage = terminal.textStorage {
            storage.beginEditing()
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
            let replacementRange = NSRange(
                location: edit.range.location,
                length: edit.replacement.utf16.count
            )
            if replacementRange.length > 0 {
                storage.addAttributes(
                    [
                        .foregroundColor: NSColor.white,
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    ],
                    range: replacementRange
                )
            }
            storage.endEditing()
        }
        terminal.selectedRanges = terminalSelections(
            preserving: selection,
            applying: edit,
            utf16Length: text.utf16.count
        )
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
            guard let remapped = remapTerminalSelection(original, applying: edit) else { return nil }
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
