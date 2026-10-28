import CmuxNextIcons
import SwiftUI
import CmuxNextDesign

/// Variant `list`: one chronological list. Open requests are pinned on top
/// with inline answer controls; notices and closed requests follow, newest
/// first, with unread dots.
struct FeedListView: View {
    let model: FeedModel
    @Environment(\.feedColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            FeedHeader(model: model)
            if model.summary.listIsEmpty {
                FeedEmptyState(text: FeedStrings.empty)
            } else {
                FeedRowsHost(model: model, mode: .list)
            }
        }
    }
}

/// Puts the AppKit ``FeedRowsView`` in the SwiftUI panel with the panel's colors. An open
/// request keeps its SwiftUI card (inline answer controls) until those controls are AppKit; the
/// event rows, which are nearly all of the list, are AppKit (plans/cmux-next/no-swiftui-DESIGN.md).
struct FeedRowsHost: NSViewRepresentable {
    let model: FeedModel
    let mode: FeedRowsView.Mode
    var filter = FeedInboxFilter()
    @Environment(\.feedColors) private var colors

    func makeNSView(context: Context) -> FeedRowsView {
        let view = FeedRowsView(model: model, mode: mode)
        update(view)
        return view
    }

    func updateNSView(_ view: FeedRowsView, context: Context) {
        update(view)
    }

    private func update(_ view: FeedRowsView) {
        let colors = colors, model = model
        if mode == .list {
            view.requestCard = { [weak view] item, last in
                let card = AnyView(VStack(spacing: 0) {
                    FeedRequestCard(item: item, model: model)
                    FeedHairline().padding(.horizontal, 14)
                }
                .environment(\.feedColors, colors).tint(colors.primary))
                if let hosting = last as? FeedCardHost {
                    hosting.rootView = card
                    return hosting
                }
                let hosting = FeedCardHost(rootView: card)
                hosting.onResize = { [weak view] in view?.cardResized(item.id) }
                return hosting
            }
        }
        view.filter = filter
        view.apply(colors.basket)
    }
}

/// Title, badge count, and Mark All Read.
struct FeedHeader: View {
    let model: FeedModel
    @Environment(\.feedColors) private var colors

    var body: some View {
        let counts = model.summary.counts
        HStack(spacing: 8) {
            Text(FeedStrings.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.primary)
            if counts.badge > 0 {
                Text(verbatim: "\(counts.badge)")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(colors.secondary)
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(colors.hover))
            }
            Spacer()
            Button { model.markAllRead() } label: {
                Icon(.actionConfirm, size: 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(colors.secondary)
            .themedHelp(FeedStrings.markAllRead)
            .accessibilityLabel(FeedStrings.markAllRead).accessibilityIdentifier("cmux.feed.markAllRead")
            .disabled(counts.unreadNotices == 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

/// An open request in the list: what it asks and how to answer, inline.
struct FeedRequestCard: View {
    let item: FeedItem
    let model: FeedModel
    @Environment(\.feedColors) private var colors
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                FeedGlyph(item: item).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.primary)
                        .lineLimit(2)
                    PosterLine(item: item, now: model.now)
                }
                Spacer(minLength: 0)
            }
            FeedPromptSummary(item: item)
                .padding(.leading, 26)
            FeedAnswerControls(item: item, model: model, density: .inline)
                .padding(.leading, 26)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(hovering ? colors.hover.opacity(0.5) : .clear)
        .opacity(model.isPending(item.id) ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}


/// An open request's SwiftUI card in the AppKit list; tells the list when its content resized
/// (an answer form opened, an error showed), so the row is measured again.
final class FeedCardHost: NSHostingView<AnyView> {
    var onResize: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onResize?()
    }
}
