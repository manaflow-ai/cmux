import CmuxNextIcons
import Foundation
import SwiftUI

/// The kind of an item as a small registry icon; color only for attention.
struct FeedGlyph: View {
    let item: FeedItem
    /// The point size of the text the glyph sits beside.
    var size: CGFloat = 12
    @Environment(\.feedColors) private var colors

    var body: some View {
        Icon(Self.icon(for: item), size: Self.side(forTextSize: size))
            .foregroundStyle(tint)
            .frame(width: size + 6, height: size + 6)
    }

    /// The icon box beside `size` point text.
    static func side(forTextSize size: CGFloat) -> CGFloat {
        .iconRowSize(forLabelPointSize: size)
    }

    static func icon(for item: FeedItem) -> IconName {
        switch item.prompt {
        case .notice:
            switch item.poster.kind {
            case .integration: .integration
            case .server, .vm: .machineRemote
            case .automation: .automation
            case .system: item.context.terminal != nil ? .terminal : .notification
            default: .notification
            }
        case let .approve(approve):
            switch approve.action.type {
            case .command: .terminal
            case .edit: .actionEdit
            case .network: .network
            case .install: .package
            case .tool, .custom: .tools
            }
        case .question: .agentQuestion
        case .choice: .feedChoice
        case .confirm: .actionConfirm
        case .signIn: .accountSignin
        case .passkey: .accountPasskey
        case .review: .actionReview
        case .input: .feedInput
        case .file: .fileNew
        case .handoff: .agentHandoff
        case .custom: .feedCustom
        }
    }

    private var tint: Color {
        if item.isOpenRequest { return item.priority >= .high ? colors.attention : colors.primary }
        if item.state == .expired || item.state == .cancelled { return colors.tertiary }
        return colors.secondary
    }
}

/// A label whose icon is a registry icon at the row size of its
/// `textSize` point text; the caller sets the font.
struct FeedIconLabel: View {
    let title: String
    let icon: IconName
    let textSize: CGFloat

    init(_ title: String, icon: IconName, textSize: CGFloat) {
        self.title = title
        self.icon = icon
        self.textSize = textSize
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Icon(icon, size: .iconRowSize(forLabelPointSize: textSize))
        }
    }
}

/// The unread mark: a small dot in the theme's foreground.
struct UnreadDot: View {
    let visible: Bool
    @Environment(\.feedColors) private var colors

    var body: some View {
        Circle()
            .fill(visible ? colors.primary : .clear)
            .frame(width: 6, height: 6)
    }
}

/// "Claude Code · api-server · 3m", plus "This Mac only" for local items.
struct PosterLine: View {
    let item: FeedItem
    let now: Date
    @Environment(\.feedColors) private var colors

    var body: some View {
        HStack(spacing: 5) {
            Text(item.poster.displayLabel).lineLimit(1)
            Text(verbatim: "·")
            Text(FeedRelativeTime.string(item.createdAt, now: now)).monospacedDigit()
            if item.home.isLocal {
                Icon(.machineLocal, size: .iconRowSize(forLabelPointSize: 11)).help(FeedStrings.thisMac)
            }
            if item.count > 1 {
                Text(verbatim: "×\(item.count)").monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(colors.tertiary)
    }
}
