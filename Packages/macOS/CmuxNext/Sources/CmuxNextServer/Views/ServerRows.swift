import SwiftUI

/// A row that shows a gray wash on hover and runs `action` on click.
struct HoverRow<Content: View>: View {
    var action: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var hovering = false
    @Environment(\.serverColors) private var colors

    var body: some View {
        let row = content
            .padding(.horizontal, 8)
            .frame(minHeight: ServerMetrics.rowHeight)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering && action != nil ? colors.hover : .clear))
            .onHover { hovering = $0 }
        if let action {
            Button(action: action) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

/// A labeled metric row: glyph, title, trailing value.
struct MetricRow: View {
    let symbol: String
    let title: String
    let value: String
    var dot: Color?
    var action: (() -> Void)?
    @Environment(\.serverColors) private var colors

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(colors.secondary).frame(width: 18)
                Text(title).font(.system(size: 12.5)).foregroundStyle(colors.primary)
                Spacer(minLength: 8)
                if let dot { StateDot(color: dot, size: 6) }
                Text(value).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(colors.secondary).lineLimit(1)
                if action != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(colors.tertiary)
                }
            }
        }
    }
}

/// Small uppercase group title.
struct GroupTitle: View {
    let text: String
    @Environment(\.serverColors) private var colors

    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(colors.tertiary)
            .textCase(.uppercase).padding(.horizontal, 8).padding(.top, 6)
    }
}
