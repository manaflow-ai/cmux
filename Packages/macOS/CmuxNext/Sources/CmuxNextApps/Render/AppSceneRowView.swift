import CmuxNextDesign
import SwiftUI

/// `Row`: the standard sidebar row, laid out with the built-in sidebar
/// item metrics (inset, icon box, text offset, title and subtitle fonts,
/// row heights) so app sections read as native rows. The hover wash and
/// selection pill are local.
struct AppSceneRowView: View {
    @Environment(\.appSceneColors) private var colors
    let node: AppSceneNode
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let subtitle = node.string("subtitle").flatMap { $0.isEmpty ? nil : $0 }
        let iconBox = Metrics.smallIconSize + Metrics.space2
        let tint = colors.token(node.props["tint"]) ?? (node.flag("selected") ? colors.primary : colors.secondary)
        HStack(spacing: Metrics.space3) {
            if let symbol = node.string("symbol") {
                Image(systemName: symbol)
                    .font(.system(size: Metrics.smallIconSize - Metrics.space1))
                    .foregroundStyle(tint)
                    .frame(width: iconBox, height: iconBox)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(node.string("title") ?? "")
                    .font(Font(node.flag("unread") ? Typography.bodyEmphasized : Typography.body))
                    .foregroundStyle(colors.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Font(Typography.caption))
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let badge = node.string("badge"), !badge.isEmpty {
                AppSceneBadge(text: badge, tone: node.props["tint"])
            } else if node.flag("unread") {
                Circle().fill(colors.primary).frame(width: Metrics.space2 + 2, height: Metrics.space2 + 2)
            }
            if let accessory = node.string("accessory") {
                Image(systemName: accessory)
                    .font(.system(size: Metrics.smallIconSize - Metrics.space2))
                    .foregroundStyle(colors.tertiary)
            }
        }
        .padding(.leading, Metrics.space3)
        .padding(.trailing, Metrics.space3)
        .frame(maxWidth: .infinity, minHeight: subtitle == nil ? Metrics.sidebarRowHeight : Metrics.sidebarRowHeightWithSubtitle, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous)
                .fill(pillColor)
        }
        .padding(.horizontal, Metrics.space3)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(node.flag("onTap") ? .isButton : [])
    }

    private var pillColor: Color {
        if node.flag("selected") { return colors.selection }
        return isHovered && node.flag("onTap") ? colors.hover : .clear
    }
}

/// `Badge`: a small count or label capsule in a semantic tone.
struct AppSceneBadge: View {
    @Environment(\.appSceneColors) private var colors
    let text: String
    let tone: AppJSON?

    var body: some View {
        let toneColor = colors.token(tone)
        Text(text)
            .font(Font(Typography.shortcut))
            .monospacedDigit()
            .foregroundStyle(toneColor ?? colors.secondary)
            .padding(.horizontal, Metrics.space2)
            .frame(minHeight: Metrics.iconSize)
            .background(Capsule().fill((toneColor ?? colors.secondary).opacity(0.14)))
    }
}

/// `EmptyState`: a quiet glyph, title and optional message.
struct AppSceneEmptyState: View {
    @Environment(\.appSceneColors) private var colors
    let node: AppSceneNode

    var body: some View {
        VStack(spacing: Metrics.space2) {
            if let symbol = node.string("symbol") {
                Image(systemName: symbol)
                    .font(.system(size: Metrics.iconSize))
                    .foregroundStyle(colors.tertiary)
            }
            Text(node.string("title") ?? "")
                .font(Font(Typography.bodyEmphasized))
                .foregroundStyle(colors.secondary)
            if let message = node.string("message") {
                Text(message)
                    .font(Font(Typography.caption))
                    .foregroundStyle(colors.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.space4)
        .padding(.horizontal, Metrics.space4)
    }
}
