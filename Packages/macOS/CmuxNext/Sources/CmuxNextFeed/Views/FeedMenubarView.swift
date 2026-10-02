import SwiftUI

/// Reads the colors in a tracked scope for the menu bar host.
struct FeedMenubarRoot: View {
    let model: FeedModel
    let appearance: FeedAppearance

    var body: some View {
        FeedMenubarView(model: model)
            .environment(\.feedColors, appearance.colors)
            .tint(appearance.colors.primary)
    }
}

/// Variant `compact` (menu bar popover): open requests only, one line each
/// with the primary answer buttons, and "Open Feed" at the bottom.
struct FeedMenubarView: View {
    let model: FeedModel
    @Environment(\.feedColors) private var colors

    var body: some View {
        let items = model.menubarItems
        VStack(spacing: 0) {
            if case .disconnected = model.connection {
                FeedBanner(text: FeedStrings.disconnected)
            }
            if items.isEmpty {
                FeedEmptyState(text: FeedStrings.menubarEmpty)
                    .frame(height: 120)
            } else {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        FeedMenubarRow(item: item, model: model)
                    }
                }
                .padding(6)
            }
            FeedHairline()
            Button { model.openFeed() } label: {
                HStack {
                    Text(FeedStrings.openFeed)
                    Spacer()
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.secondary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: FeedTunables.menubarWidth.value)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One open request on one line: glyph, title over poster, answer buttons.
struct FeedMenubarRow: View {
    let item: FeedItem
    let model: FeedModel
    @Environment(\.feedColors) private var colors
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FeedGlyph(item: item, size: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(colors.primary).lineLimit(1)
                Text(item.poster.displayLabel).font(.system(size: 10.5)).foregroundStyle(colors.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.open(item.id) }
            FeedAnswerControls(item: item, model: model, density: .menubar)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(minHeight: FeedTunables.rowHeight.value + 8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? colors.hover : .clear))
        .opacity(model.isPending(item.id) ? 0.55 : 1)
        .onHover { hovering = $0 }
    }
}
