public import AppKit
public import CMUXAgentLaunch
import Foundation

public extension NSAttributedString {
    /// The submission parts (text runs and inline attachments) carried by this
    /// attributed string, in document order.
    var textBoxSubmissionParts: [TextBoxSubmissionPart] {
        let raw = string as NSString
        let fullRange = NSRange(location: 0, length: length)
        var parts: [TextBoxSubmissionPart] = []

        enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            if let inlineAttachment = value as? (any TextBoxInlineAttachmentCarrying) {
                parts.append(.attachment(inlineAttachment.textBoxAttachment))
            } else {
                let text = raw.substring(with: range)
                let strippedText = TextBoxInputTextMarkers().stringByStrippingNonTextMarkers(from: text)
                guard !strippedText.isEmpty else { return }
                parts.append(.text(strippedText))
            }
        }

        return parts
    }

    /// The flattened, boundary-spaced submission text for this attributed string.
    var textBoxFormattedSubmissionText: String {
        textBoxSubmissionParts.textBoxFormattedSubmissionText
    }
}
