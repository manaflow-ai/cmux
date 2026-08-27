import Foundation

extension TerminalPastePreparationResult {
    var transferredFileURLs: [URL] {
        switch self {
        case .terminal(.fileURLs(let fileURLs)):
            return fileURLs
        case .composer(.attachments(let attachments)):
            return attachments.map(\.fileURL)
        case .terminal, .composer, .pasteboardSnapshot:
            return []
        }
    }

    func replacingTransferredFileURLs(
        _ replacementsByPath: [String: URL]
    ) -> TerminalPastePreparationResult {
        switch self {
        case .terminal(.fileURLs(let fileURLs)):
            return .terminal(
                .fileURLs(
                    fileURLs.map {
                        replacementsByPath[$0.standardizedFileURL.path] ?? $0
                    }
                )
            )
        case .composer(.attachments(let attachments)):
            return .composer(
                .attachments(
                    attachments.map { attachment in
                        TextBoxPreparedAttachment(
                            fileURL: replacementsByPath[
                                attachment.fileURL.standardizedFileURL.path
                            ] ?? attachment.fileURL,
                            thumbnailPNGData: attachment.thumbnailPNGData
                        )
                    }
                )
            )
        case .terminal, .composer, .pasteboardSnapshot:
            return self
        }
    }
}
