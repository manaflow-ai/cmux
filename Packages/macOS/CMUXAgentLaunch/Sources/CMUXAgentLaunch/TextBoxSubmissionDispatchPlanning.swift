import Foundation

// Submission/dispatch planning for textbox input. Pure transforms that turn a
// raw textbox string or an array of `TextBoxSubmissionPart` into the ordered
// `TextBoxSubmitDispatchEvent` list the app's event runner executes, plus the
// visible-text readiness check used while waiting for a paste to render. None of
// this touches live UI state, so it lives as extensions on the value types it
// operates on rather than a namespace utility.

public extension String {
    /// The submitted paste text for a raw textbox string, or `nil` when the
    /// string carries no submittable (non-whitespace) content.
    var textBoxSubmittedPasteText: String? {
        let trimmedForEnabledState = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedForEnabledState.isEmpty else { return nil }
        return trimmingCharacters(in: .newlines)
    }

    /// Whether the given expected text is now visible, comparing this visible
    /// text against the captured `baseline` (self is the current visible text).
    func textBoxVisibleTextReady(expectedText: String, baseline: String) -> Bool {
        let visibleText = self
        let trimmedExpectedText = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExpectedText.isEmpty else {
            return visibleText != baseline
        }
        if visibleText.textBoxOccurrenceCount(of: expectedText) >
            baseline.textBoxOccurrenceCount(of: expectedText) {
            return true
        }

        let normalizedExpected = trimmedExpectedText.textBoxNormalizedVisibleText
        guard !normalizedExpected.isEmpty,
              normalizedExpected != expectedText else {
            return false
        }
        return visibleText.textBoxNormalizedVisibleText.textBoxOccurrenceCount(of: normalizedExpected) >
            baseline.textBoxNormalizedVisibleText.textBoxOccurrenceCount(of: normalizedExpected)
    }
}

public extension Array where Element == TextBoxSubmissionPart {
    /// The submittable parts for this array, trimming boundary newlines, or `nil`
    /// when the flattened content is entirely whitespace.
    var textBoxSubmittedParts: [TextBoxSubmissionPart]? {
        let flattened = map { part in
            switch part {
            case .text(let text):
                return text
            case .attachment(let attachment):
                return attachment.submissionText
            }
        }.joined()
        guard !flattened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return textBoxTrimBoundaryNewlines
    }

    /// The ordered dispatch events for submitting these parts to a terminal whose
    /// agent context is `terminalAgentContext`.
    func textBoxDispatchEvents(terminalAgentContext: String) -> [TextBoxSubmitDispatchEvent] {
        guard let inputParts = textBoxSubmittedParts else {
            return [.namedKey(TextBoxTerminalKey.returnKey.rawValue)]
        }

        let isClaude = TextBoxAgentDetection.isClaudeCode(context: terminalAgentContext)
        var containsNewline = false

        for part in inputParts {
            switch part {
            case .text(let text):
                if text.contains("\n") || text.contains("\r") {
                    containsNewline = true
                }
            case .attachment:
                break
            }
        }

        let submitKey = isClaude && containsNewline ? "ctrl+enter" : TextBoxTerminalKey.returnKey.rawValue
        if isClaude, inputParts.textBoxContainsImageAttachment {
            return inputParts.textBoxClaudeSequentialImageDispatchEvents(submitKey: submitKey)
        }

        let pastePayload = inputParts.textBoxFormattedSubmissionText
        return [.pasteText(pastePayload), .namedKey(submitKey)]
    }

    private var textBoxContainsImageAttachment: Bool {
        contains { part in
            if case .attachment(let attachment) = part {
                return attachment.isImage
            }
            return false
        }
    }

    private func textBoxClaudeSequentialImageDispatchEvents(
        submitKey: String
    ) -> [TextBoxSubmitDispatchEvent] {
        var events: [TextBoxSubmitDispatchEvent] = []
        var attachmentNeedsBoundarySpace = false

        func appendPastedText(_ text: String) {
            guard !text.isEmpty else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(.pasteText(text))
                return
            }
            events.append(.captureVisibleTextBaseline)
            events.append(.pasteText(text))
            if let waitNeedle = text.textBoxVisibleTextWaitNeedle {
                events.append(.waitForVisibleText(waitNeedle))
            }
        }

        func appendText(_ text: String) {
            guard !text.isEmpty else { return }
            var textToPaste = text
            if attachmentNeedsBoundarySpace,
               text.first?.isWhitespace != true {
                textToPaste = " " + textToPaste
            }
            appendPastedText(textToPaste)
            attachmentNeedsBoundarySpace = false
        }

        for part in self {
            switch part {
            case .text(let text):
                appendText(text)
            case .attachment(let attachment):
                guard !attachment.submissionText.isEmpty else { continue }
                if attachmentNeedsBoundarySpace {
                    appendPastedText(" ")
                }
                if attachment.isImage,
                   let pastePath = attachment.textBoxClaudeImagePastePath {
                    events.append(.captureClaudeImageTokenBaseline)
                    events.append(.captureClipboardReadBaseline)
                    events.append(.pasteFilePath(pastePath))
                    events.append(.waitForClipboardRead)
                    events.append(.waitForClaudeImageToken(attachment.submissionText))
                    attachmentNeedsBoundarySpace = true
                } else {
                    appendPastedText(attachment.submissionText)
                    attachmentNeedsBoundarySpace = attachment.submissionText.last?.isWhitespace != true
                }
            }
        }

        if attachmentNeedsBoundarySpace {
            appendPastedText(" ")
        }
        events.append(.namedKey(submitKey))
        return events
    }

    private var textBoxTrimBoundaryNewlines: [TextBoxSubmissionPart] {
        var result = self

        while let first = result.first {
            guard case .text(let text) = first else { break }
            let trimmed = text.textBoxTrimmingLeadingNewlines
            if trimmed.isEmpty {
                result.removeFirst()
            } else {
                result[0] = .text(trimmed)
                break
            }
        }

        while let last = result.last {
            guard case .text(let text) = last else { break }
            let trimmed = text.textBoxTrimmingTrailingNewlines
            if trimmed.isEmpty {
                result.removeLast()
            } else {
                result[result.count - 1] = .text(trimmed)
                break
            }
        }

        return result
    }
}

private extension TextBoxSubmissionAttachment {
    var textBoxClaudeImagePastePath: String? {
        guard isImage else { return nil }
        guard let localPath = localURL?.standardizedFileURL.path else { return nil }
        return submissionPath == localPath ? submissionPath : localPath
    }
}

private extension String {
    /// Maximum number of characters of a long paste segment to wait for becoming
    /// visible before considering the paste rendered.
    static let textBoxVisibleTextWaitMaxCharacters = 160

    var textBoxVisibleTextWaitNeedle: String? {
        let nonNewlineTrimmed = trimmingCharacters(in: .newlines)
        guard !nonNewlineTrimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard nonNewlineTrimmed.count > String.textBoxVisibleTextWaitMaxCharacters else {
            return self
        }

        let lastLine = nonNewlineTrimmed
            .split(omittingEmptySubsequences: false) { character in
                character == "\n" || character == "\r"
            }
            .last
            .map(String.init) ?? nonNewlineTrimmed
        let visibleLine = lastLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nonNewlineTrimmed
            : lastLine
        return String(visibleLine.suffix(String.textBoxVisibleTextWaitMaxCharacters))
    }

    var textBoxTrimmingLeadingNewlines: String {
        String(drop { character in
            character == "\n" || character == "\r"
        })
    }

    var textBoxTrimmingTrailingNewlines: String {
        var result = self
        while let last = result.last,
              last == "\n" || last == "\r" {
            result.removeLast()
        }
        return result
    }

    func textBoxOccurrenceCount(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = startIndex..<endIndex
        while let range = range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<endIndex
        }
        return count
    }

    var textBoxNormalizedVisibleText: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
