import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Submit Pipeline
@MainActor
protocol TextBoxSubmitSurfaceControlling: AnyObject {
    var clipboardReadGeneration: Int { get }
    var textBoxSubmitObservationWindow: NSWindow? { get }
    var textBoxSubmitTerminalSurface: TerminalSurface? { get }

    func visibleText() -> String?
    @discardableResult
    func sendKeyText(_ text: String) -> Bool
    @discardableResult
    func sendText(_ text: String) -> Bool
    @discardableResult
    func sendNamedKey(_ keyName: String) -> TerminalSurface.NamedKeySendResult
    @discardableResult
    func performBindingAction(_ action: String) -> Bool
}

extension TerminalSurface: TextBoxSubmitSurfaceControlling {
    var textBoxSubmitObservationWindow: NSWindow? {
        hostedView.window
    }

    var textBoxSubmitTerminalSurface: TerminalSurface? {
        self
    }
}

@MainActor
enum TextBoxSubmit {
    struct CompletionContext: Equatable {
        enum Failure: Equatable {
            case terminalWriteRejected
        }

        var confirmedClaudeImageSubmissionTexts: [String: Int] = [:]
        var failure: Failure?

        var didSubmit: Bool {
            failure == nil
        }

        static let empty = CompletionContext()
    }

#if DEBUG
    static var debugWaitTimeoutSecondsOverride: TimeInterval?

    static func debugRunDispatchEvents(
        _ events: [DispatchEvent],
        via surface: TextBoxSubmitSurfaceControlling,
        onComplete: ((CompletionContext) -> Void)? = nil
    ) {
        TextBoxSubmitEventRunner.run(events, via: surface, onComplete: onComplete)
    }

    static func debugResetForTesting() {
        TextBoxSubmitEventRunner.resetForTesting()
        debugWaitTimeoutSecondsOverride = nil
    }
#endif

    private static let visibleTextWaitMaxCharacters = 160

    enum DispatchEvent: Equatable {
        case keyText(String)
        case pasteText(String)
        case pasteFilePath(String)
        case namedKeyRepeat(String, Int)
        case namedKey(String)
        case captureClipboardReadBaseline
        case waitForClipboardRead
        case captureVisibleTextBaseline
        case waitForVisibleText(String)
        case captureClaudeImageTokenBaseline
        case waitForClaudeImageToken(String)
    }

    static func submittedPasteText(for text: String) -> String? {
        let trimmedForEnabledState = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedForEnabledState.isEmpty else { return nil }
        return text.trimmingCharacters(in: .newlines)
    }

    static func submittedParts(_ parts: [TextBoxSubmissionPart]) -> [TextBoxSubmissionPart]? {
        let flattened = parts.map { part in
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
        return trimBoundaryNewlines(from: parts)
    }

    static func dispatchEvents(
        for parts: [TextBoxSubmissionPart],
        terminalAgentContext: String
    ) -> [DispatchEvent] {
        guard let inputParts = submittedParts(parts) else {
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
        if isClaude, containsImageAttachment(inputParts) {
            return claudeSequentialImageDispatchEvents(from: inputParts, submitKey: submitKey)
        }

        let pastePayload = TextBoxSubmissionFormatter.formattedText(from: inputParts)
        return [.pasteText(pastePayload), .namedKey(submitKey)]
    }

    static func send(
        _ text: String,
        via surface: TerminalSurface,
        terminalAgentContext: String,
        onComplete: ((CompletionContext) -> Void)? = nil
    ) {
        let parts = submittedPasteText(for: text).map { [TextBoxSubmissionPart.text($0)] } ?? []
        send(parts, via: surface, terminalAgentContext: terminalAgentContext, onComplete: onComplete)
    }

    static func send(
        _ parts: [TextBoxSubmissionPart],
        via surface: TerminalSurface,
        terminalAgentContext: String,
        onComplete: ((CompletionContext) -> Void)? = nil
    ) {
        let events = dispatchEvents(for: parts, terminalAgentContext: terminalAgentContext)
        TextBoxSubmitEventRunner.run(events, via: surface, onComplete: onComplete)
    }

    static func cleanupAttachmentsAfterSubmit(
        from parts: [TextBoxSubmissionPart],
        terminalAgentContext: String,
        completionContext: CompletionContext = .empty
    ) -> [TextBoxAttachment] {
        let isClaude = TextBoxAgentDetection.isClaudeCode(context: terminalAgentContext)
        var confirmedClaudeImageSubmissionTexts = completionContext.confirmedClaudeImageSubmissionTexts
        return parts.compactMap { part -> TextBoxAttachment? in
            if case .attachment(let attachment) = part { return attachment }
            return nil
        }.filter { attachment in
            guard attachment.cleanupLocalURLWhenDisposed else { return false }
            if isClaude, attachment.isImage {
                let remainingCount = confirmedClaudeImageSubmissionTexts[attachment.submissionText, default: 0]
                guard remainingCount > 0 else { return false }
                confirmedClaudeImageSubmissionTexts[attachment.submissionText] = remainingCount - 1
                return true
            }
            return !attachment.submitsLocalFilePath
        }
    }

    private static func containsImageAttachment(_ parts: [TextBoxSubmissionPart]) -> Bool {
        parts.contains { part in
            if case .attachment(let attachment) = part {
                return attachment.isImage
            }
            return false
        }
    }

    private static func claudeSequentialImageDispatchEvents(
        from parts: [TextBoxSubmissionPart],
        submitKey: String
    ) -> [DispatchEvent] {
        var events: [DispatchEvent] = []
        var attachmentNeedsBoundarySpace = false

        func appendPastedText(_ text: String) {
            guard !text.isEmpty else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(.pasteText(text))
                return
            }
            events.append(.captureVisibleTextBaseline)
            events.append(.pasteText(text))
            if let waitNeedle = visibleTextWaitNeedle(for: text) {
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

        for part in parts {
            switch part {
            case .text(let text):
                appendText(text)
            case .attachment(let attachment):
                guard !attachment.submissionText.isEmpty else { continue }
                if attachmentNeedsBoundarySpace {
                    appendPastedText(" ")
                }
                if attachment.isImage,
                   let pastePath = claudeImagePastePath(for: attachment) {
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

    private static func visibleTextWaitNeedle(for text: String) -> String? {
        let nonNewlineTrimmed = text.trimmingCharacters(in: .newlines)
        guard !nonNewlineTrimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard nonNewlineTrimmed.count > visibleTextWaitMaxCharacters else {
            return text
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
        return String(visibleLine.suffix(visibleTextWaitMaxCharacters))
    }

    private static func claudeImagePastePath(for attachment: TextBoxAttachment) -> String? {
        guard attachment.isImage else { return nil }
        guard let localPath = attachment.localURL?.standardizedFileURL.path else { return nil }
        return attachment.submissionPath == localPath ? attachment.submissionPath : localPath
    }

    private static func trimBoundaryNewlines(from parts: [TextBoxSubmissionPart]) -> [TextBoxSubmissionPart] {
        var result = parts

        while let first = result.first {
            guard case .text(let text) = first else { break }
            let trimmed = trimmingLeadingNewlines(text)
            if trimmed.isEmpty {
                result.removeFirst()
            } else {
                result[0] = .text(trimmed)
                break
            }
        }

        while let last = result.last {
            guard case .text(let text) = last else { break }
            let trimmed = trimmingTrailingNewlines(text)
            if trimmed.isEmpty {
                result.removeLast()
            } else {
                result[result.count - 1] = .text(trimmed)
                break
            }
        }

        return result
    }

    private static func trimmingLeadingNewlines(_ text: String) -> String {
        String(text.drop { character in
            character == "\n" || character == "\r"
        })
    }

    private static func trimmingTrailingNewlines(_ text: String) -> String {
        var result = text
        while let last = result.last,
              last == "\n" || last == "\r" {
            result.removeLast()
        }
        return result
    }

    static func visibleTextReady(
        expectedText: String,
        visibleText: String,
        baseline: String
    ) -> Bool {
        let trimmedExpectedText = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExpectedText.isEmpty else {
            return visibleText != baseline
        }
        if occurrenceCount(of: expectedText, in: visibleText) >
            occurrenceCount(of: expectedText, in: baseline) {
            return true
        }

        let normalizedExpected = normalizedVisibleText(trimmedExpectedText)
        guard !normalizedExpected.isEmpty,
              normalizedExpected != expectedText else {
            return false
        }
        return occurrenceCount(of: normalizedExpected, in: normalizedVisibleText(visibleText)) >
            occurrenceCount(of: normalizedExpected, in: normalizedVisibleText(baseline))
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func normalizedVisibleText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

