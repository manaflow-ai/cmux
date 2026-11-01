import CmuxNextIcons
import SwiftUI
import CmuxNextDesign

/// Variant `list`: one chronological list. Open requests are pinned on top
/// with inline answer controls; notices and closed requests follow, newest
/// first, with unread dots.
struct FeedListView: View {
    let model: FeedModel

    var body: some View {
        // AppKit from here down (FeedListPane): this body reads nothing from the model, so no owner
        // event re-evaluates SwiftUI.
        FeedListPaneHost(model: model)
    }
}

/// Puts the AppKit ``FeedListPane`` in the SwiftUI panel with the panel's colors. An open
/// request keeps its SwiftUI card (inline answer controls) until those controls are AppKit; the
/// bar and the event rows are AppKit (plans/cmux-next/no-swiftui-DESIGN.md).
struct FeedListPaneHost: NSViewRepresentable {
    let model: FeedModel
    @Environment(\.feedColors) private var colors

    func makeNSView(context: Context) -> FeedListPane {
        let pane = FeedListPane(model: model)
        update(pane)
        return pane
    }

    func updateNSView(_ pane: FeedListPane, context: Context) {
        update(pane)
    }

    private func update(_ pane: FeedListPane) {
        FeedRowsHost.installCards(on: pane.rows, model: model, colors: colors)
        pane.apply(colors.basket)
    }
}

/// Puts the AppKit ``FeedRowsView`` in the SwiftUI Inbox page with the page's colors.
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
        if mode == .list { Self.installCards(on: view, model: model, colors: colors) }
        view.filter = filter
        view.apply(colors.basket)
    }

    /// Open requests' cards: the SwiftUI request card, hosted once per request and updated in place.
    static func installCards(on view: FeedRowsView, model: FeedModel, colors: FeedColors) {
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
                        .font(.system(size: TypeScale.body, weight: .semibold))
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
