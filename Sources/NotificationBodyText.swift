import SwiftUI

struct NotificationBodyText: View {
    private static let maxMarkdownBodyCharacters = 4_096

    let notification: TerminalNotification
    let font: Font
    let color: Color
    let lineLimit: Int

    var body: some View {
        bodyText
            .font(font)
            .foregroundColor(color)
            .lineLimit(lineLimit)
    }

    @ViewBuilder
    private var bodyText: some View {
        if notification.bodyFormat == .markdown,
           notification.body.count <= Self.maxMarkdownBodyCharacters,
           let attributed = try? AttributedString(markdown: notification.body) {
            Text(attributed)
        } else {
            Text(notification.body)
        }
    }
}
