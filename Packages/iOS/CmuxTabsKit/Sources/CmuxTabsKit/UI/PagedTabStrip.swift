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
/// glass chips in one row, the active chip centered on the screen. The row tracks the finger 1:1
/// (rubber-banding past either end), and a release pages it one chip at most (`StripPaging`) on
/// the toolbar's swipe spring. Its position, a fractional page, drives the page under it 1:1
/// while the finger is down (`onMove`); a release or a tapped chip hands the page it goes to to
/// the parent (`onRelease`), which runs the page on the same spring, so strip and page land
/// together. Its ends fade out before Back and Tabs (the soft scroll edge effect).
struct PagedTabStrip: View {
    static let newTabID = "tabs.strip.new"

    var entries: [StripEntry]
    var activeID: String?
    var restToken: Int = 0
    /// The strip's frame in the toolbar (screen points) and the screen width: the active chip is
    /// centered on the screen.
    var frame: CGRect
    var screenWidth: CGFloat
    /// The finger moved the strip: the page it shows, as a fractional index into `entries`.
    var onMove: (CGFloat) -> Void
    /// The strip is heading to `entries[index]` on the swipe spring (a release or a tapped chip);
    /// the active page itself when a drag springs back.
    var onRelease: (Int) -> Void
    /// The active chip was tapped (the page menu, or the address field of a web page).
    var onActiveTap: () -> Void

    @Environment(\.tabsKitTheme) private var theme
    @State private var widths: [String: CGFloat] = [:]
    /// The row's scroll offset: page `i` is `paging.offset(i)`.
    @State private var x: CGFloat = 0
    /// The offset the finger's drag started from (nil: no drag).
    @State private var dragBase: CGFloat?
    /// What the strip last did, for UI tests (its accessibility value).
    @State private var trace = ""
    /// When the last drag ended: a chip's tap that lands with a drag's release is the drag's.
    @State private var dragEnded = Date.distantPast
    /// The row is moving (a drag, or its spring after one): every chip shows in full. At rest
    /// only the active chip does; the others fade to a dim title without a capsule (Conductor).
    @State private var moving = false
    /// Bumped by each move, so only the last spring's end settles the row.
    @State private var moveToken = 0

    private var activeIndex: Int { entries.firstIndex { $0.id == activeID } ?? 0 }

    private var paging: StripPaging {
        let m = theme.metrics
        return StripPaging(widths: entries.map { widths[$0.id] ?? estimate($0) }, gap: m.stripChipGap,
                           anchor: screenWidth / 2 - frame.minX, viewport: frame.width)
    }

    var body: some View {
        let p = paging
        let at = p.position(offset: x)
        HStack(spacing: theme.metrics.stripChipGap) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                chip(entry, index: index, emphasis: moving ? 1 : max(0, 1 - abs(CGFloat(index) - at)))
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in
                        if widths[entry.id] != w { widths[entry.id] = w }
                    }
            }
        }
        .fixedSize()
        .offset(x: p.leadingPad - x)
        .frame(width: frame.width, height: frame.height, alignment: .leading)
        .contentShape(.rect)
        .clipped()
        .mask(StripEdgeFade(width: frame.width, fade: theme.metrics.stripEdgeFade))
        .highPriorityGesture(drag)
        .onChange(of: activeID) { _, _ in if dragBase == nil { rest() } }
        .onChange(of: p) { _, _ in if dragBase == nil { rest() } }
        .onChange(of: restToken) { _, _ in withAnimation(theme.motion.resolve(theme.motion.swipe)) { rest() } }
        .onAppear { rest() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabs.strip")
        .accessibilityValue(trace)
    }

    /// Puts the active chip in the middle (no animation unless the caller animates).
    private func rest() { x = paging.offset(activeIndex) }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { v in
                let p = paging
                let base = dragBase ?? x
                if dragBase == nil { dragBase = base }
                if !moving { withAnimation(.easeOut(duration: 0.12)) { moving = true } }
                moveToken += 1
                x = StripPaging.clamp(base - v.translation.width, low: 0, high: p.offset(lastDragPage))
                onMove(p.position(offset: x))
            }
            .onEnded { v in
                let p = paging
                let base = dragBase ?? x
                dragBase = nil
                dragEnded = Date()
                let start = Int(p.position(offset: base).rounded())
                let page = min(lastDragPage, p.target(start: start, projected: base - v.predictedEndTranslation.width, velocity: -v.velocity.width))
                trace = "release from \(start) at \(Int(x)) v \(Int(-v.velocity.width)) -> \(page)"
                go(to: page)
            }
    }

    /// Springs the row to `index` and tells the parent, which springs the page with it.
    private func go(to index: Int) {
        moveToken += 1
        let token = moveToken
        if !moving { withAnimation(.easeOut(duration: 0.12)) { moving = true } }
        withAnimation(theme.motion.resolve(theme.motion.swipe)) {
            x = paging.offset(index)
        } completion: {
            guard token == moveToken, dragBase == nil else { return }
            withAnimation(.easeOut(duration: 0.25)) { moving = false }
        }
        onRelease(index)
    }

    /// The last page a drag reaches: the last tab. The New Tab chip after it shows, and a tap
    /// on it makes a tab, but a swipe never pages onto a tab that does not exist.
    private var lastDragPage: Int {
        let last = entries.count - 1
        if last > 0, case .newTab = entries[last] { return last - 1 }
        return max(0, last)
    }

    private var chipMaxWidth: CGFloat {
        StripPaging.chipMaxWidth(viewport: frame.width, gap: theme.metrics.stripChipGap, cap: theme.metrics.stripChipMaxWidth)
    }

    private func estimate(_ entry: StripEntry) -> CGFloat {
        let m = theme.metrics
        let title: String = if case .tab(let tab) = entry { tab.title } else { "New Tab" }
        let text = CGFloat(title.count) * m.stripChipFont * 0.55
        return min(chipMaxWidth, 2 * m.stripChipPadding + 16 + m.stripChipIconGap + text)
    }

    // MARK: Chips

    @ViewBuilder private func chip(_ entry: StripEntry, index: Int, emphasis: CGFloat) -> some View {
        let m = theme.metrics
        let isActive = entry.id == activeID
        Button {
            guard dragBase == nil, Date().timeIntervalSince(dragEnded) > 0.25 else { return }
            if isActive {
                onActiveTap()
            } else {
                trace = "tap \(index) from \(activeIndex)"
                go(to: index)
            }
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
            .foregroundStyle(theme.colors.label)
            .padding(.horizontal, m.stripChipPadding)
            .frame(height: m.stripChipHeight)
            .frame(maxWidth: chipMaxWidth)
            .contentShape(.capsule)
        }
        .buttonStyle(GlassContentButtonStyle())
        // A drag moves the row, not one chip: only a press at rest lights the chip's glass.
        // At rest a neighbor has no capsule, only its dim title (Conductor); it gains one as the row moves.
        .glassEffect(isActive && !moving ? .regular.interactive() : moving ? .regular : .identity, in: .capsule)
        .opacity(isActive || moving ? 1 : 0.38 + 0.62 * Double(emphasis))
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: chipMaxWidth)
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
