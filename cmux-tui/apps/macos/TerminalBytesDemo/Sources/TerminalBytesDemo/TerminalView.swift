import AppKit
import SwiftUI

enum TerminalInput: Equatable {
    case bytes(Data)
    case paste(String)
}

final class TerminalTextView: NSTextView {
    var submit: ((TerminalInput) -> Void)?
    var pasteboardText: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    }

    func configureForTerminal() {
        isEditable = false
        isSelectable = true
    }

    override func keyDown(with event: NSEvent) {
        let bytes: [UInt8]?
        switch event.keyCode {
        case 36, 76: bytes = [13]
        case 51: bytes = [127]
        case 123: bytes = Array("\u{1B}[D".utf8)
        case 124: bytes = Array("\u{1B}[C".utf8)
        case 125: bytes = Array("\u{1B}[B".utf8)
        case 126: bytes = Array("\u{1B}[A".utf8)
        default:
            if event.modifierFlags.contains(.command) {
                super.keyDown(with: event)
                return
            }
            if event.modifierFlags.contains(.control) {
                bytes = event.characters?.data(using: .utf8).map(Array.init)
            } else {
                interpretKeyEvents([event])
                return
            }
        }
        if let bytes {
            submit?(.bytes(Data(bytes)))
        }
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
           isTerminalFirstResponder {
            return submitPaste()
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        if item.action == #selector(paste(_:)) {
            return hasPasteboardText
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
        guard let value = pasteboardText(), !value.isEmpty else { return false }
        submit?(.paste(value))
        return true
    }
}

private final class TerminalContainerView: NSScrollView {
    var resized: ((TerminalGeometry) -> Void)?

    override func layout() {
        super.layout()
        resized?(terminalGeometry(width: contentSize.width, height: contentSize.height))
    }
}

struct TerminalView: NSViewRepresentable {
    let text: String
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
        terminal.textContainerInset = NSSize(width: 8, height: 8)
        terminal.isVerticallyResizable = true
        terminal.isHorizontallyResizable = true
        terminal.autoresizingMask = [.width]
        terminal.submit = submit
        scroll.documentView = terminal
        scroll.resized = resize
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let terminal = scroll.documentView as? TerminalTextView,
              terminal.string != text else { return }
        let selection = terminal.selectedRanges
        let visible = scroll.documentVisibleRect
        let followedBottom = visible.maxY >= terminal.bounds.maxY - 24
        terminal.string = text
        terminal.textColor = .white
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.selectedRanges = selection.filter {
            NSMaxRange($0.rangeValue) <= terminal.string.utf16.count
        }
        if followedBottom {
            terminal.scrollToEndOfDocument(nil)
        } else {
            terminal.scroll(visible.origin)
        }
    }
}
