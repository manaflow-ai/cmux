import Foundation

private let promptEchoScanLimit = 4096

extension ChatConversationStore {
    func pendingEchoBatchIDs(
        in messages: [ChatMessage],
        reconciledPendingEchoIDs: Set<String>
    ) -> Set<String> {
        guard !reconciledPendingEchoIDs.isEmpty else { return [] }
        var echoIDs = reconciledPendingEchoIDs
        var precedingAttachmentIDs: [String] = []
        for message in messages where message.role == .user {
            switch message.kind {
            case .attachment:
                precedingAttachmentIDs.append(message.id)
            case .prose:
                if reconciledPendingEchoIDs.contains(message.id) {
                    echoIDs.formUnion(precedingAttachmentIDs)
                }
                precedingAttachmentIDs.removeAll(keepingCapacity: true)
            default:
                precedingAttachmentIDs.removeAll(keepingCapacity: true)
            }
        }
        return echoIDs
    }

    func appendClearsStreamingPreview(
        _ message: ChatMessage,
        pendingEchoBatchIDs: Set<String>
    ) -> Bool {
        (message.role == .agent && messageContainsProse(message))
            || (message.role == .user && !pendingEchoBatchIDs.contains(message.id))
    }

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
        let promptTail = String(text.unicodeScalars.suffix(promptEchoScanLimit))
        return promptTail.split(whereSeparator: \.isNewline).contains { line in
            promptLine(String(line), hasSuffixPreview: previewText)
        }
    }

    private func promptLine(_ line: String, hasSuffixPreview previewText: String) -> Bool {
        let lineText = normalizedPromptEchoText(line)
        guard !lineText.isEmpty else { return false }
        guard lineText != previewText else { return true }
        guard lineText.count > previewText.count,
              lineText.hasSuffix(previewText) else { return false }
        guard let boundary = lineText.dropLast(previewText.count).last else { return false }
        return boundary.isWhitespace || boundary.isNewline
    }

    private func normalizedPromptEchoText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
