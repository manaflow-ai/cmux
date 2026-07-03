import AppKit
import Foundation

enum TextBoxSubmissionFormatter {
    static func parts(from attributed: NSAttributedString) -> [TextBoxSubmissionPart] {
        let raw = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: attributed.length)
        var parts: [TextBoxSubmissionPart] = []

        attributed.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            if let inlineAttachment = value as? TextBoxInlineTextAttachment {
                parts.append(.attachment(inlineAttachment.textBoxAttachment))
            } else {
                let text = raw.substring(with: range)
                let strippedText = TextBoxInputTextView.stringByStrippingNonTextMarkers(from: text)
                guard !strippedText.isEmpty else { return }
                parts.append(.text(strippedText))
            }
        }

        return parts
    }

    static func formattedText(from parts: [TextBoxSubmissionPart]) -> String {
        var result = ""
        var attachmentNeedsBoundarySpace = false

        for part in parts {
            switch part {
            case .text(let text):
                guard !text.isEmpty else { continue }
                if attachmentNeedsBoundarySpace,
                   text.first?.isWhitespace != true {
                    result += " "
                }
                result += text
                attachmentNeedsBoundarySpace = false
            case .attachment(let attachment):
                guard !attachment.submissionText.isEmpty else { continue }
                if attachmentNeedsBoundarySpace {
                    result += " "
                }
                result += attachment.submissionText
                attachmentNeedsBoundarySpace = result.last?.isWhitespace != true
            }
        }

        if attachmentNeedsBoundarySpace {
            result += " "
        }

        return result.trimmingCharacters(in: .newlines)
    }

    static func formattedText(from attributed: NSAttributedString) -> String {
        formattedText(from: parts(from: attributed))
    }

    static func hasSubmittableContent(_ parts: [TextBoxSubmissionPart]) -> Bool {
        parts.contains { part in
            switch part {
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .attachment:
                return true
            }
        }
    }
}
