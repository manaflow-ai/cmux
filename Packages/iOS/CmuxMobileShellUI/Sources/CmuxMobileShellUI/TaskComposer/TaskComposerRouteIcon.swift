#if os(iOS)
import SwiftUI

struct TaskComposerRouteIcon: View {
    enum Content {
        case symbol(String)
        case emoji(String)
    }

    let content: Content

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))

            switch content {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            case .emoji(let emoji):
                Text(emoji)
                    .font(.system(size: 17))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

struct TaskComposerRouteLabel: View {
    let icon: TaskComposerRouteIcon.Content
    let title: String
    let value: String
    let valueFont: Font
    let valueTruncationMode: Text.TruncationMode
    let chevronSystemName: String

    var body: some View {
        HStack(spacing: 8) {
            TaskComposerRouteIcon(content: icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(value)
                    .font(valueFont)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .truncationMode(valueTruncationMode)
            }
            Spacer(minLength: 0)
            Image(systemName: chevronSystemName)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}
#endif
