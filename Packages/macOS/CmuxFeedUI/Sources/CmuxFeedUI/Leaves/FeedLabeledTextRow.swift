public import SwiftUI

/// A two-column Feed row: a fixed-width semibold label and a value that renders
/// as either plain text or inline markdown. Shared by the context recap block
/// and the long-form question prompt.
public struct FeedLabeledTextRow: View {
    let label: String
    let text: String
    let labelColor: Color
    let textColor: Color
    var rendersMarkdown: Bool = false

    public init(
        label: String,
        text: String,
        labelColor: Color,
        textColor: Color,
        rendersMarkdown: Bool = false
    ) {
        self.label = label
        self.text = text
        self.labelColor = labelColor
        self.textColor = textColor
        self.rendersMarkdown = rendersMarkdown
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(labelColor)
                .frame(width: 48, alignment: .leading)
            if rendersMarkdown {
                FeedMarkdownInlineText(
                    text: text,
                    fontSize: 11,
                    foregroundColor: textColor
                )
            } else {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
