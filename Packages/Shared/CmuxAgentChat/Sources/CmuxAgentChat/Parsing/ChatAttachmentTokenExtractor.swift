import Foundation

struct ChatAttachmentTokenExtractor: Sendable {
    struct Extraction: Sendable, Equatable {
        let attachments: [ChatAttachment]
        let remainingProse: String
    }

    private static let imageExtensions: Set<String> = [
        "gif", "heic", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]

    func extractLeadingAttachments(from text: String) -> Extraction {
        var cursor = text.startIndex
        var attachments: [ChatAttachment] = []

        while cursor < text.endIndex {
            let tokenStart = firstNonWhitespace(in: text, at: cursor)
            guard tokenStart < text.endIndex else {
                cursor = tokenStart
                break
            }
            let tokenEnd = firstWhitespace(in: text, at: tokenStart)
            let token = String(text[tokenStart..<tokenEnd])
            guard isClipboardImagePath(token) else {
                break
            }
            attachments.append(
                ChatAttachment(
                    media: .image,
                    displayName: (token as NSString).lastPathComponent,
                    hostPath: token
                )
            )
            cursor = tokenEnd
        }

        guard !attachments.isEmpty else {
            return Extraction(attachments: [], remainingProse: text)
        }
        let remaining = String(text[cursor...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Extraction(attachments: attachments, remainingProse: remaining)
    }

    private func firstNonWhitespace(in text: String, at start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index
    }

    private func firstWhitespace(in text: String, at start: String.Index) -> String.Index {
        var index = start
        while index < text.endIndex, !text[index].isWhitespace {
            index = text.index(after: index)
        }
        return index
    }

    private func isClipboardImagePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let basename = (path as NSString).lastPathComponent
        guard let match = basename.wholeMatch(
            of: /^clipboard-\d{4}-\d{2}-\d{2}-\d{6}-[0-9a-fA-F]{8}\.([A-Za-z0-9]+)$/
        ) else {
            return false
        }
        return Self.imageExtensions.contains(String(match.1).lowercased())
    }
}
