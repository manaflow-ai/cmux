import Foundation

/// One run of a textbox submission: literal text or an inline attachment.
public enum TextBoxSubmissionPart {
    /// A literal run of text.
    case text(String)
    /// An inline attachment contributing its submission text.
    case attachment(any TextBoxSubmissionAttachment)
}

public extension Array where Element == TextBoxSubmissionPart {
    /// The flattened submission text for these parts, inserting boundary spaces
    /// around attachments and trimming surrounding newlines.
    var textBoxFormattedSubmissionText: String {
        var result = ""
        var attachmentNeedsBoundarySpace = false

        for part in self {
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

    /// Whether any part contributes non-whitespace text or an attachment.
    var hasSubmittableTextBoxContent: Bool {
        contains { part in
            switch part {
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .attachment:
                return true
            }
        }
    }
}
