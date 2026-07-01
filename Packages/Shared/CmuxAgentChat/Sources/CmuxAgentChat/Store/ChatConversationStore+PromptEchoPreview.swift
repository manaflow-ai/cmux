import Foundation

private let promptEchoScanLimit = 4096

extension ChatConversationStore {
    /// The screen-scraped live preview can momentarily read the wrapped tail of
    /// the user's prompt as agent prose before the first answer token is painted.
    func livePreviewEchoesLatestUserPrompt(
        _ preview: ChatMessage,
        in messages: [ChatMessage],
        pending: [ChatPendingOutbound]
    ) -> Bool {
        guard case .prose(let previewProse) = preview.kind else { return false }
        let previewText = normalizedPromptEchoText(previewProse.text)
        guard !previewText.isEmpty else { return false }
        if let latestPending = pending.last(where: { !$0.text.isEmpty && canEchoFromTerminal($0) }),
           promptText(latestPending.text, hasSuffixPreview: previewText) {
            return true
        }
        guard let latestUserIndex = messages.lastIndex(where: { $0.role == .user }) else { return false }
        let hasAgentProseAfterUser = messages[(latestUserIndex + 1)...].contains {
            $0.role == .agent && messageContainsProse($0)
        }
        guard !hasAgentProseAfterUser else { return false }
        guard case .prose(let userProse) = messages[latestUserIndex].kind else { return false }
        return promptText(userProse.text, hasSuffixPreview: previewText)
    }

    private func messageContainsProse(_ message: ChatMessage) -> Bool {
        if case .prose = message.kind { return true }
        return false
    }

    private func canEchoFromTerminal(_ item: ChatPendingOutbound) -> Bool {
        switch item.delivery {
        case .sending, .delivered:
            return true
        case .queued, .failed:
            return false
        }
    }

    private func promptText(_ text: String, hasSuffixPreview previewText: String) -> Bool {
        let promptText = normalizedPromptEchoText(String(text.unicodeScalars.suffix(promptEchoScanLimit)))
        guard promptText.count > previewText.count,
              promptText.hasSuffix(previewText) else { return false }
        guard let boundary = promptText.dropLast(previewText.count).last else { return false }
        return boundary.isWhitespace || boundary.isNewline
    }

    private func normalizedPromptEchoText(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
