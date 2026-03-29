import AppKit

/// NSTextView subclass with Cmd+S save, tab-to-spaces, and auto-indent.
/// Uses both performKeyEquivalent AND a local event monitor to catch
/// Cmd+S even when CMUX's menu system consumes key equivalents.
final class SaveableTextView: NSTextView {
    var onSave: (() -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.window?.firstResponder === self,
                      event.modifierFlags.contains(.command),
                      event.charactersIgnoringModifiers == "s" else {
                    return event
                }
                self.onSave?()
                return nil
            }
        } else if window == nil, let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Tab inserts 2 spaces instead of a tab character
    override func insertTab(_ sender: Any?) {
        insertText("  ", replacementRange: selectedRange())
    }

    // Auto-indent: copy leading whitespace from current line on Enter
    override func insertNewline(_ sender: Any?) {
        let currentString = string as NSString
        let cursorLocation = selectedRange().location
        let lineRange = currentString.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let currentLine = currentString.substring(with: lineRange)

        var leadingWhitespace = ""
        for char in currentLine {
            if char == " " || char == "\t" {
                leadingWhitespace.append(char)
            } else {
                break
            }
        }

        super.insertNewline(sender)
        if !leadingWhitespace.isEmpty {
            insertText(leadingWhitespace, replacementRange: selectedRange())
        }
    }
}
