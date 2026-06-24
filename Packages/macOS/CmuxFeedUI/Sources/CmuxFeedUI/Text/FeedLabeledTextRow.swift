public import SwiftUI

/// A two-column "Label: value" row used inside Feed context blocks. The value
/// optionally renders Claude inline markdown.
public struct FeedLabeledTextRow: View {
    let label: String
    let text: String
    let labelColor: Color
    let textColor: Color
    var rendersMarkdown: Bool = false

    /// Creates a labeled "Label: value" row.
    /// - Parameters:
    ///   - label: Leading label text.
    ///   - text: Value text shown next to the label.
    ///   - labelColor: Color for the label.
    ///   - textColor: Color for the value text.
    ///   - rendersMarkdown: When `true`, the value renders Claude inline markdown.
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
