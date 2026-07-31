import AppKit
import SwiftUI

private final class TerminalTextView: NSTextView {
    var send: ((Data) -> Void)?
    var sendPaste: ((String) -> Void)?

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
            bytes = event.characters?.data(using: .utf8).map(Array.init)
        }
        if let bytes {
            send?(Data(bytes))
        }
    }

    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string) {
            sendPaste?(value)
        }
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
    let send: (Data) -> Void
    let paste: (String) -> Void
    let resize: (TerminalGeometry) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TerminalContainerView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .black

        let terminal = TerminalTextView()
        terminal.isEditable = false
        terminal.isSelectable = true
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
        terminal.send = send
        terminal.sendPaste = paste
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
