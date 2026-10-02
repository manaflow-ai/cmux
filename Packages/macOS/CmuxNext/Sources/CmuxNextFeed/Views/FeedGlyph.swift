import Foundation
import SwiftUI

/// The kind of an item as a small symbol; color only for attention.
struct FeedGlyph: View {
    let item: FeedItem
    var size: CGFloat = 12
    @Environment(\.feedColors) private var colors

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size + 6, height: size + 6)
    }

    private var symbol: String {
        switch item.prompt {
        case .notice:
            switch item.poster.kind {
            case .integration: "arrow.triangle.pull"
            case .server, .vm: "server.rack"
            case .automation: "gearshape.2"
            case .system: item.context.terminal != nil ? "terminal" : "bell"
            default: "bell"
            }
        case let .approve(approve):
            switch approve.action.type {
            case .command: "terminal"
            case .edit: "pencil.line"
            case .network: "network"
            case .install: "shippingbox"
            case .tool, .custom: "wrench.and.screwdriver"
            }
        case .question: "text.bubble"
        case .choice: "list.bullet"
        case .confirm: "checkmark.circle"
        case .signIn: "person.badge.key"
        case .passkey: "person.badge.key.fill"
        case .review: "doc.text.magnifyingglass"
        case .input: "rectangle.and.pencil.and.ellipsis"
        case .file: "doc.badge.plus"
        case .handoff: "hand.raised"
        case .custom: "square.grid.2x2"
        }
    }

    private var tint: Color {
        if item.isOpenRequest { return item.priority >= .high ? colors.attention : colors.primary }
        if item.state == .expired || item.state == .cancelled { return colors.tertiary }
        return colors.secondary
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
                Image(systemName: "laptopcomputer").help(FeedStrings.thisMac)
            }
            if item.count > 1 {
                Text(verbatim: "×\(item.count)").monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(colors.tertiary)
    }
}
