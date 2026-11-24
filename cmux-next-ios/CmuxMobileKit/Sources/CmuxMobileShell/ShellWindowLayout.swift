#if os(iOS)
import CmuxMobileDesign
import CmuxMobileLinkFFI
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The shell's layout at the window's size: one pane on a phone, a list
/// beside its detail on an unfolded foldable (or any window at least
/// `TWO_PANE_MIN_WIDTH` wide whose shorter side is an unfolded one's). The
/// decision is Rust's (cmux-mobile-link-ffi `window_layout`); this only
/// carries it to the views. Design: cmuxterm-hq `docs/design/ios-foldable.md`.
struct ShellWindowLayout: Equatable {
    var twoPane: Bool
    /// The list column's width in two-pane layout.
    var listWidth: CGFloat

    static let compact = ShellWindowLayout(twoPane: false, listWidth: 0)

    init(twoPane: Bool, listWidth: CGFloat) {
        self.twoPane = twoPane
        self.listWidth = listWidth
    }

    init(windowSize size: CGSize) {
        let layout = windowLayout(width: Double(size.width), height: Double(size.height))
        self.init(twoPane: layout.twoPane, listWidth: layout.twoPane ? CGFloat(layout.listWidth) : 0)
    }
}

extension EnvironmentValues {
    @Entry var shellWindowLayout = ShellWindowLayout.compact
}

/// Reads the window's size (safe area included) and hands its layout to
/// everything inside. A fold or unfold resizes the window live: the layout
/// changes once as the size crosses Rust's threshold, and every element it
/// moves moves in that one animation (the list slides in or out as the
/// detail narrows or widens), so nothing jumps.
struct ShellWindowLayoutReader: ViewModifier {
    @State private var layout = ShellWindowLayout.compact

    func body(content: Content) -> some View {
        content
            .environment(\.shellWindowLayout, layout)
            .onGeometryChange(for: ShellWindowLayout.self) { proxy in
                let insets = proxy.safeAreaInsets
                return ShellWindowLayout(windowSize: CGSize(
                    width: proxy.size.width + insets.leading + insets.trailing,
                    height: proxy.size.height + insets.top + insets.bottom))
            } action: { next in
                guard next != layout else { return }
                withAnimation(theme.motion.gentle.animation.unlessReduceMotion) { layout = next }
            }
    }
}

/// A list beside its detail when the window has room, else the detail alone
/// (whose stack shows the list at its root). The detail stays at one place in
/// the view tree in both layouts, so its `NavigationStack`, the screen it
/// shows and their state (a terminal's scroll position, the focused tab, a
/// composer's draft) survive every fold and unfold.
struct ListDetailSplit<List: View, Detail: View>: View {
    let layout: ShellWindowLayout
    @ViewBuilder let list: () -> List
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            if layout.twoPane {
                HStack(spacing: 0) {
                    list()
                        .frame(width: layout.listWidth)
                    Rectangle()
                        .fill(theme.colors.separator.color)
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("shell.listColumn")
            }
            detail()
                .frame(maxWidth: .infinity)
        }
    }
}

/// The detail's root in two-pane layout, before anything is open in it.
struct DetailPlaceholder: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.colors.bg.color.ignoresSafeArea())
            .accessibilityIdentifier("shell.detailPlaceholder")
    }
}
#endif
