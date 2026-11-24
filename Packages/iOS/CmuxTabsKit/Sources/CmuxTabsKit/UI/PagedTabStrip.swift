#if os(iOS)
import SwiftUI

/// One page of the paged strip: a tab, or the trailing New Tab chip.
enum StripEntry: Hashable, Identifiable {
    case tab(TabsKitTab)
    case newTab

    var id: String {
        switch self {
        case .tab(let tab): tab.id
        case .newTab: PagedTabStrip.newTabID
        }
    }
}

/// Conductor's horizontal tabs (`TabsKitToolbarStyle.pagedTabs`): the active tab's pane's tabs as
/// glass chips in a native horizontal scroll view, the active chip centered on the screen. A
/// drag pages it one chip at a time (`StripPaging`); its position (a fractional page) drives the
/// page under it 1:1 (`onMove`), and where it comes to rest picks the tab (`onSettle`). Its ends
/// fade under Back and Tabs with the system's soft scroll edge effect.
struct PagedTabStrip: View {
    static let newTabID = "tabs.strip.new"

    var entries: [StripEntry]
    var activeID: String?
    var restToken: Int = 0
    /// The strip's frame in the toolbar (screen points) and the screen width: the active chip is
    /// centered on the screen, not on the strip.
    var frame: CGRect
    var screenWidth: CGFloat
    /// The strip moved by the person (a drag, its fling, or a tapped chip's scroll): the page
    /// it shows as a fractional index into `entries`; nil when it rests on the active page.
    var onMove: (CGFloat?) -> Void
    /// The strip came to rest on `entries[index]`.
    var onSettle: (Int) -> Void
    /// The active chip was tapped (the page menu, or the address field of a web page).
    var onActiveTap: () -> Void

    @Environment(\.tabsKitTheme) private var theme
    @State private var widths: [String: CGFloat] = [:]
    @State private var position = ScrollPosition(idType: String.self)
    @State private var offset: CGFloat = 0
    @State private var phase: ScrollPhase = .idle
    /// The page the current drag began on (the paging limit: one page per drag).
    @State private var dragStart = 0
    /// A chip tap scrolled the strip: its animation drives the page like a drag does.
    @State private var tapScroll = false

    private var activeIndex: Int { entries.firstIndex { $0.id == activeID } ?? 0 }

    private var paging: StripPaging {
        let m = theme.metrics
        return StripPaging(widths: entries.map { widths[$0.id] ?? estimate($0) }, gap: m.stripChipGap,
                           anchor: screenWidth / 2 - frame.minX, viewport: frame.width)
    }

    /// The person is moving the strip (or it settles after a fling or a tapped chip's scroll).
    private var driven: Bool {
        switch phase {
        case .tracking, .interacting, .decelerating: true
        case .animating: tapScroll
        case .idle: false
        @unknown default: false
        }
    }

    var body: some View {
        let p = paging
        let at = p.position(offset: offset)
        ScrollView(.horizontal) {
            HStack(spacing: theme.metrics.stripChipGap) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    chip(entry, emphasis: max(0, 1 - abs(CGFloat(index) - at)))
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in
                            if widths[entry.id] != w { widths[entry.id] = w }
                        }
                }
            }
            .padding(.leading, p.leadingPad)
            .padding(.trailing, p.trailingPad)
            .frame(height: frame.height)
        }
        .scrollIndicators(.hidden)
        .scrollPosition($position)
        .scrollTargetBehavior(StripPagingBehavior(paging: p, start: dragStart))
        .scrollEdgeEffectStyle(.soft, for: .horizontal)
        .scrollClipDisabled(false)
        .frame(width: frame.width, height: frame.height)
        .mask(StripEdgeFade(width: frame.width, fade: theme.metrics.stripEdgeFade))
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
            offset = x
            report()
        }
        .onScrollPhaseChange { old, new, context in
            phase = new
            if new == .interacting || new == .tracking, old == .idle || old == .animating {
                tapScroll = false
                dragStart = Int(p.position(offset: context.geometry.contentOffset.x).rounded())
            }
            if new == .idle {
                tapScroll = false
                let page = Int(p.position(offset: offset).rounded())
                onMove(nil)
                onSettle(min(max(0, page), max(0, entries.count - 1)))
            } else {
                report()
            }
        }
        // The active tab changed elsewhere (the grid, a tap, a settle): rest on its chip.
        .onChange(of: activeID) { _, _ in rest(animated: false) }
        .onChange(of: p) { _, _ in if phase == .idle { rest(animated: false) } }
        .onChange(of: restToken) { _, _ in rest(animated: true) }
        .onAppear { rest(animated: false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabs.strip")
    }

    private func report() {
        guard driven else { return }
        let at = paging.position(offset: offset)
        onMove(abs(at - CGFloat(activeIndex)) < 0.0005 ? nil : at)
    }

    /// Scrolls to the active chip.
    private func rest(animated: Bool) {
        let x = paging.offset(activeIndex)
        guard abs(x - offset) > 0.5 else { return }
        if animated {
            withAnimation(theme.motion.resolve(theme.motion.swipe)) { position.scrollTo(x: x) }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { position.scrollTo(x: x) }
        }
    }

    /// A tap on another chip scrolls to it, and the page follows the scroll.
    private func select(_ index: Int) {
        tapScroll = true
        dragStart = activeIndex
        withAnimation(theme.motion.resolve(theme.motion.swipe)) { position.scrollTo(x: paging.offset(index)) }
    }

    private func estimate(_ entry: StripEntry) -> CGFloat {
        let m = theme.metrics
        let title: String = if case .tab(let tab) = entry { tab.title } else { "New Tab" }
        let text = CGFloat(title.count) * m.stripChipFont * 0.55
        return min(m.stripChipMaxWidth, 2 * m.stripChipPadding + 16 + m.stripChipIconGap + text)
    }

    // MARK: Chips

    @ViewBuilder private func chip(_ entry: StripEntry, emphasis: CGFloat) -> some View {
        let m = theme.metrics
        let index = entries.firstIndex { $0.id == entry.id } ?? 0
        let isActive = entry.id == activeID
        Button {
            if isActive { onActiveTap() } else { select(index) }
        } label: {
            HStack(spacing: m.stripChipIconGap) {
                switch entry {
                case .tab(let tab):
                    Image(systemName: tab.systemImage)
                        .font(.system(size: m.stripChipFont - 1, weight: .medium))
                        .opacity(0.75)
                    Text(tab.title.isEmpty ? "Untitled" : tab.title)
                        .font(.system(size: m.stripChipFont, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                case .newTab:
                    Image(systemName: "plus")
                        .font(.system(size: m.stripChipFont + 2, weight: .regular))
                    Text("New Tab")
                        .font(.system(size: m.stripChipFont, weight: .medium))
                        .lineLimit(1)
                }
            }
            // The resting page's chip reads at full strength; the others dim, and a chip
            // brightens as the strip carries it to the middle.
            .foregroundStyle(theme.colors.label.opacity(0.5 + 0.5 * Double(emphasis)))
            .padding(.horizontal, m.stripChipPadding)
            .frame(height: m.stripChipHeight)
            .frame(maxWidth: m.stripChipMaxWidth)
            .contentShape(.capsule)
        }
        .buttonStyle(GlassContentButtonStyle())
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: m.stripChipMaxWidth)
        .accessibilityIdentifier(entry.id == Self.newTabID ? Self.newTabID : "tabs.strip.chip.\(entry.id)")
        .accessibilityLabel(label(entry))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func label(_ entry: StripEntry) -> String {
        switch entry {
        case .tab(let tab): tab.title.isEmpty ? "Untitled" : tab.title
        case .newTab: "New Tab"
        }
    }
}

/// One page per drag, toward a fling (`StripPaging.target`).
struct StripPagingBehavior: ScrollTargetBehavior {
    var paging: StripPaging
    var start: Int

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let page = paging.target(start: start, projected: target.rect.minX, velocity: context.velocity.dx)
        target.rect.origin.x = paging.offset(page)
    }
}

/// The strip's ends fade out over `fade` points, so a chip slides out under Back and Tabs
/// instead of being cut at the strip's edge.
struct StripEdgeFade: View {
    var width: CGFloat
    var fade: CGFloat

    var body: some View {
        let f = width > 0 ? min(0.45, fade / width) : 0
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: f),
            .init(color: .black, location: 1 - f),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}
#endif
