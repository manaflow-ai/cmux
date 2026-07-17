import SwiftUI

struct FeedLabeledTextRow: View {
    let label: String
    let text: String
    let labelColor: Color
    let textColor: Color
    var rendersMarkdown: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .cmuxFont(size: 10, weight: .semibold)
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
                    .cmuxFont(size: 11)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
