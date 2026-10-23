#if os(iOS)
import SwiftUI
import UIKit

/// One entry of a Feed event's menu (the "…" button and the long press):
/// one list, so both menus always offer the same actions.
struct FeedMenuAction: Identifiable {
    let title: String
    let systemImage: String
    var isDestructive = false
    let perform: @MainActor () -> Void

    var id: String { title }
}

/// The "…" button of a Feed row: a UIKit button whose menu is built only
/// when it opens. A SwiftUI `Menu` per row resolved its whole menu (and its
/// date title) for every row that scrolled in, the largest single cost of a
/// Feed row (verify/feed-perf-20261021.md: 60 to 17 ms/s of hitches without it).
struct FeedMenuButton: UIViewRepresentable {
    /// The menu's section title (the event's time), built when the menu opens.
    let title: @MainActor () -> String
    let actions: @MainActor () -> [FeedMenuAction]

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// One template image for every row.
    @MainActor static let image = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline))?
        .withRenderingMode(.alwaysTemplate)

    func makeUIView(context: Context) -> UIButton {
        // A plain image button: a `UIButton.Configuration` cost a visual-provider rebuild per row.
        let button = UIButton(type: .custom)
        button.setImage(FeedMenuButton.image, for: .normal)
        button.tintColor = .secondaryLabel
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "Event actions"
        let coordinator = context.coordinator
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                MainActor.assumeIsolated { completion([coordinator.menu()]) }
            },
        ])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.title = title
        context.coordinator.actions = actions
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: 44, height: 44)
    }

    @MainActor
    final class Coordinator {
        var title: () -> String = { "" }
        var actions: () -> [FeedMenuAction] = { [] }

        func menu() -> UIMenu {
            UIMenu(title: title(), options: .displayInline, children: actions().map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.systemImage),
                         attributes: action.isDestructive ? .destructive : []) { _ in action.perform() }
            })
        }
    }
}

/// A Feed row's long-press menu. A view of its own, so SwiftUI builds its
/// body (the date title and the actions) when the menu opens, not for every
/// row that scrolls in.
struct FeedContextMenu: View {
    let title: () -> String
    let actions: () -> [FeedMenuAction]

    var body: some View {
        Section(title()) {
            ForEach(actions()) { action in
                Button(action.title, systemImage: action.systemImage, role: action.isDestructive ? .destructive : nil, action: action.perform)
            }
        }
    }
}

/// The share sheet for a Feed event, made when Share is tapped: a
/// `ShareLink` per row built its share representation for every row that
/// scrolled in (verify/feed-perf-20261021.md).
@MainActor
enum FeedShareSheet {
    /// Presents the sheet from the key window's frontmost controller, anchored at `source` (the
    /// Share button's frame in window coordinates; on iPad the popover points at it).
    static func present(_ text: String, from source: CGRect?) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.lazy.compactMap(\.keyWindow).first ?? scenes.first?.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard !top.isBeingDismissed else { return }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = source ?? CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            if source == nil { popover.permittedArrowDirections = [] }
        }
        top.present(sheet, animated: true)
    }
}
#endif

#if os(iOS)
/// The Feed cell's column: a leading-aligned vertical stack that proposes the
/// column's exact width to each part and measures each part once.
///
/// A `VStack` (inside the cell's `HStack`) sizes flexible children by
/// measuring them several times (`StackLayout.prioritize`, ideal and concrete
/// passes), and the Feed's `LazyVStack` measures every row that scrolls in:
/// that was the largest part of a scrolled-in row's main-thread cost
/// (verify/feed-perf-20261021.md). The width is always known here (the
/// Feed's width less the avatar), so one pass gives the same result.
struct FeedColumnLayout: Layout {
    var spacing: CGFloat

    /// Each part's height at `width`: one proposal per part. No cache across
    /// passes: a part can change height (Show more, a web body's measured
    /// height) without the parts changing, and SwiftUI keeps each part's
    /// answer for the same proposal within a pass.
    private func measure(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        let proposal = ProposedViewSize(width: width, height: nil)
        return subviews.map { $0.sizeThatFits(proposal).height }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let heights = measure(subviews, width: width)
        let visible = heights.filter { $0 > 0 }
        let height = heights.reduce(0, +) + spacing * CGFloat(max(visible.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = measure(subviews, width: bounds.width)
        var y = bounds.minY
        var first = true
        for (subview, height) in zip(subviews, heights) {
            // An empty part (an `EmptyView` branch) takes no room and no spacing, as in a VStack.
            if height > 0 {
                if !first { y += spacing }
                first = false
            }
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height
        }
    }
}

/// The Feed cell: a fixed-width leading part (the avatar) and the column,
/// which gets exactly the rest of the width (see `FeedColumnLayout`).
struct FeedCellLayout: Layout {
    var leading: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 375
        let column = max(width - leading - spacing, 0)
        let avatar = subviews.first.map { $0.sizeThatFits(.init(width: leading, height: nil)).height } ?? 0
        let content = subviews.dropFirst().first.map { $0.sizeThatFits(.init(width: column, height: nil)).height } ?? 0
        return CGSize(width: width, height: max(avatar, content))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = max(bounds.width - leading - spacing, 0)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: leading, height: nil))
        subviews.dropFirst().first?.place(at: CGPoint(x: bounds.minX + leading + spacing, y: bounds.minY), anchor: .topLeading,
                                          proposal: .init(width: column, height: nil))
    }
}
#endif

#if os(iOS)
/// A web body's stand-in while the Feed flings: its text, without markdown
/// marks, clipped to the height the web view will take, so nothing moves when
/// the web view replaces it.
struct FeedBodyPlaceholder: View {
    let markdown: String
    let height: CGFloat

    var body: some View {
        Text(FeedInlineTextCache.shared.placeholderText(markdown))
            .font(.body)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .top)
            .clipped()
            .accessibilityLabel(Text(markdown))
    }
}
#endif
