import AppKit
import CmuxSettings
import CmuxTerminal

extension GhosttyNSView {
    // MARK: - Accessibility

    /// Expose the terminal surface as an editable accessibility element.
    /// Voice input tools frequently target AX text areas for text insertion.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityHelp() -> String? {
        "Terminal content area"
    }

    /// The active screen's text. Dictation tools compare this before and
    /// after an insertion to confirm the text landed.
    override func accessibilityValue() -> Any? {
        accessibilityTextValue()
    }

    override func accessibilityNumberOfCharacters() -> Int {
        (accessibilityTextValue() as NSString).length
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    override func accessibilityLine(for index: Int) -> Int {
        let content = accessibilityTextValue() as NSString
        let end = min(max(index, 0), content.length)
        var line = 0
        for offset in 0..<end where content.character(at: offset) == 0x0A {
            line += 1
        }
        return line
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let content = accessibilityTextValue() as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= content.length else { return nil }
        return content.substring(with: range)
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard let content = Self.accessibilityCommittedString(value) else { return }
        let inject = {
            // Diff against what clients recently read, on the main thread
            // where the snapshot lives.
            let inserted = self.accessibilityScreenTextEnabled
                ? self.terminalAccessibilityText.insertedText(settingValue: content)
                : content
            self.insertAccessibilityCommittedText(inserted)
        }
        if Thread.isMainThread {
            inject()
        } else {
            DispatchQueue.main.async(execute: inject)
        }
    }

    /// Clients that insert at the caret set the selected text instead of the
    /// whole value. A terminal only accepts input at its cursor, so the text
    /// is committed there, the same as `setAccessibilityValue(_:)`.
    override func setAccessibilitySelectedText(_ text: String?) {
        guard let text else { return }
        let inject = {
            self.insertAccessibilityCommittedText(text)
        }
        if Thread.isMainThread {
            inject()
        } else {
            DispatchQueue.main.async(execute: inject)
        }
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(setAccessibilityValue(_:)), #selector(setAccessibilitySelectedText(_:)):
            return true
        default:
            return super.isAccessibilitySelectorAllowed(selector)
        }
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        if !accessibilityScreenTextEnabled,
           let snapshot = readSelectionSnapshot() {
            // In the opt-out mode AXValue contains only the native selection,
            // so its range must use that value's coordinate space rather than
            // Ghostty's grid range (which may include terminal padding).
            return NSRange(location: 0, length: (snapshot.string as NSString).length)
        }
        return selectedRange()
    }

    override func accessibilitySelectedText() -> String? {
        guard let snapshot = readSelectionSnapshot() else { return nil }
        return snapshot.string.isEmpty ? nil : snapshot.string
    }

    private func accessibilityTextValue() -> String {
        guard accessibilityScreenTextEnabled else {
            // Keep a native selection available to AX clients while hiding the
            // unselected screen that makes Speak Selection read a whole TUI.
            return readSelectionSnapshot()?.string ?? ""
        }
        return terminalAccessibilityText.value {
            terminalSurface?.readText(region: .active)
        }
    }

    private var accessibilityScreenTextEnabled: Bool {
        TerminalCatalogSection().accessibilityScreenText.value(in: .standard)
    }

    private static func accessibilityCommittedString(_ value: Any?) -> String? {
        switch value {
        case let v as NSAttributedString:
            return v.string
        case let v as String:
            return v
        default:
            return nil
        }
    }

    /// Commits text from an accessibility client into the terminal.
    ///
    /// Single-line text keeps typed-input semantics, including a trailing
    /// newline sent as Return, so autosuggestions and a dictation tool's
    /// "press enter" keep working. Text with a line break before its end goes
    /// through the paste path instead, so a bracketed-paste-aware shell or
    /// agent receives one multi-line block rather than running each line as
    /// its own command. A trailing newline after that block still submits.
    private func insertAccessibilityCommittedText(_ content: String) {
        guard !content.isEmpty else { return }

#if DEBUG
        cmuxDebugLog("ime.ax.insert len=\(content.count)")
#endif

        let (body, lineBreaks) = TerminalAccessibilityText.splitTrailingLineBreaks(content)
        // A cold surface queues the paste but can send the Return at once, so
        // multi-line text takes the paste path only on a live runtime.
        if TerminalAccessibilityText.containsLineBreak(body),
           let terminalSurface,
           terminalSurface.hasLiveSurface {
            unmarkText()
            let payload = TerminalAccessibilityText.pastePayload(
                Self.sanitizeExternalCommittedText(body)
            )
            if !payload.isEmpty {
                terminalSurface.sendText(payload)
            }
            if !lineBreaks.isEmpty {
                withExternalCommittedText {
                    insertText(lineBreaks, replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
        } else {
            withExternalCommittedText {
                insertText(content, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }

        terminalAccessibilityText.scheduleValueChanged(for: self) { [weak self] in
            self?.releaseAccessibilityValueChangedFrameDemand()
        }
        terminalAccessibilityText.invalidate()
        retainAccessibilityValueChangedFrameDemand()
    }
}
