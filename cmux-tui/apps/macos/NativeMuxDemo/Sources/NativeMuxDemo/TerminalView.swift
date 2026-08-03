import AppKit
import SwiftUI

private let terminalNamedKeys: [UInt16: String] = [
    36: "enter", 76: "enter", 48: "tab", 53: "escape", 51: "backspace",
    117: "delete", 114: "insert", 115: "home", 119: "end", 116: "pageup",
    121: "pagedown", 123: "left", 124: "right", 125: "down", 126: "up",
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
    98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
]

private func terminalChord(for event: NSEvent) -> String? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !modifiers.contains(.command) else { return nil }
    let named = terminalNamedKeys[event.keyCode]
    let usesTextChord = modifiers.contains(.control) || modifiers.contains(.option)
    let key: String?
    if let named {
        key = named
    } else if usesTextChord,
        let characters = event.charactersIgnoringModifiers?.lowercased(),
        characters.count == 1,
        "abcdefghijklmnopqrstuvwxyz0123456789 `\\[],=-.';/".contains(characters)
    {
        key = characters == " " ? "space" : characters
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

private final class NativeTerminalTextView: NSTextView {
    var submit: ((TerminalInput) -> Void)?
    var isInputReady = false

    override func keyDown(with event: NSEvent) {
        if let chord = terminalChord(for: event), isInputReady {
            submit?(.key(chord: chord, repeat: event.isARepeat))
            return
        }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        interpretKeyEvents([event])
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        _ = replacementRange
        let value: String?
        switch insertString {
        case let string as String: value = string
        case let string as NSAttributedString: value = string.string
        default: value = nil
        }
        if let value, !value.isEmpty, isInputReady {
            submit?(.bytes(Data(value.utf8)))
        }
    }

    override func doCommand(by selector: Selector) {
        // Named terminal keys are handled in keyDown. IME-only selectors stay
        // with AppKit instead of producing a system beep.
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
            event.charactersIgnoringModifiers?.lowercased() == "v",
            let text = NSPasteboard.general.string(forType: .string),
            !text.isEmpty,
            isInputReady
        {
            submit?(.paste(text))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        _ = sender
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        submit?(.paste(text))
    }
}

private final class NativeTerminalScrollView: NSScrollView {
    var resized: ((TerminalGeometry) -> Void)?

    override func layout() {
        super.layout()
        resized?(terminalGeometry(width: contentSize.width, height: contentSize.height))
    }
}

private struct TerminalTextRepresentable: NSViewRepresentable {
    let frame: String
    let isInputReady: Bool
    let submit: (TerminalInput) -> Void
    let resize: (TerminalGeometry) -> Void

    func makeNSView(context: Context) -> NativeTerminalScrollView {
        let scroll = NativeTerminalScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(red: 0.055, green: 0.063, blue: 0.075, alpha: 1)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let text = NativeTerminalTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.drawsBackground = true
        text.backgroundColor = scroll.backgroundColor
        text.textColor = NSColor(red: 0.86, green: 0.89, blue: 0.92, alpha: 1)
        text.insertionPointColor = .white
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        scroll.documentView = text
        context.coordinator.textView = text
        text.submit = submit
        text.isInputReady = isInputReady
        scroll.resized = resize
        return scroll
    }

    func updateNSView(_ scroll: NativeTerminalScrollView, context: Context) {
        guard let text = context.coordinator.textView else { return }
        text.submit = submit
        text.isInputReady = isInputReady
        scroll.resized = resize
        guard text.string != frame else { return }
        let wasAtBottom = scroll.contentView.bounds.maxY >= (text.bounds.maxY - 24)
        let selection = text.selectedRange()
        text.string = frame
        text.setSelectedRange(
            NSRange(location: min(selection.location, text.string.utf16.count), length: 0)
        )
        if wasAtBottom {
            text.scrollRangeToVisible(NSRange(location: text.string.utf16.count, length: 0))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var textView: NativeTerminalTextView?
    }
}

struct TerminalSurfaceView: View {
    @Bindable var terminal: NativeTerminalModel

    var body: some View {
        ZStack {
            TerminalTextRepresentable(
                frame: terminal.frame,
                isInputReady: terminal.isAttached && !terminal.didExit,
                submit: terminal.submit,
                resize: terminal.resize
            )
            if !terminal.isAttached, terminal.errorMessage.isEmpty {
                ProgressView(L10n.text("terminal.connecting", "Attaching terminal…"))
                    .controlSize(.small)
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
            }
            if terminal.didExit {
                VStack {
                    Spacer()
                    Text(L10n.text("terminal.exited", "Process exited"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: .capsule)
                        .padding(10)
                }
            }
            if !terminal.errorMessage.isEmpty {
                Text(terminal.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
            }
        }
        .background(Color(nsColor: NSColor(red: 0.055, green: 0.063, blue: 0.075, alpha: 1)))
    }
}
