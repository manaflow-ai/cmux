#if os(iOS)
import SwiftUI
import UIKit

/// The tabs screen's coordinate space (zoom rects and card frames).
struct TabsScreenSpace {
    static let name = "cmux.tabskit.screen"
    /// `zoomTabId` of a tab being created with (+) before it exists.
    static let newTabMarker = "\u{0}new"
    private init() {}
}

/// Content laid out at the full page size and scaled to this view's width,
/// top aligned and clipped. Cards, the zooming tab and the live page all
/// show the same layout, so a zoom is one rect over one layout.
struct ScaledContent<Content: View>: View {
    var pageSize: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let scale = pageSize.width > 0 ? geo.size.width / pageSize.width : 1
            content
                .frame(width: pageSize.width, height: pageSize.height, alignment: .top)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
        }
        .allowsHitTesting(false)
    }
}

/// The card's close button: a 22 pt circle with a 9.5 pt semibold cross,
/// 4 pt from the card's top and trailing edges (device screenshot: 66 px
/// circle, 12 px insets at 3x). The zoom draws
/// the same glyph on the moving card.
struct CardCloseGlyph: View {
    @Environment(\.tabsKitTheme) private var theme
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.colors.cardCloseGlyph)
            .frame(width: theme.metrics.cardClose, height: theme.metrics.cardClose)
            .background(theme.colors.cardCloseFill, in: .circle)
    }
}

/// One tab card: the card content with rounded corners, close button, title row.
struct TabCard<Content: View>: View {
    var title: String
    var systemImage: String
    var pageSize: CGSize
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var showsClose: Bool
    /// Close buttons and title rows (`CardChrome`).
    var closeOpacity: Double
    var titleOpacity: Double
    var titleOffset: CGFloat = 0
    /// The zoom draws this card's content and close button; its title row
    /// stays here and fades in with the others.
    var contentHidden = false
    var onOpen: () -> Void = {}
    var onClose: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.tabsKitTheme) private var theme

    var body: some View {
        let m = theme.metrics
        VStack(spacing: 0) {
            ScaledContent(pageSize: pageSize) { content }
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                // A stretchable shadow image: `.shadow` on the clipped card
                // cost an offscreen pass per card on every scroll frame.
                .background { CardShadow(radius: radius) }
                .overlay(alignment: .topTrailing) {
                    if showsClose {
                        Button(action: onClose) {
                            CardCloseGlyph()
                                .padding(4)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .opacity(closeOpacity)
                        .allowsHitTesting(closeOpacity > 0.5)
                        .accessibilityLabel("Close \(title)")
                    }
                }
                .opacity(contentHidden ? 0 : 1)
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 14))
                    .foregroundStyle(theme.colors.secondaryLabel)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: width, height: m.titleRow)
            .padding(.top, 2)
            .offset(y: titleOffset)
            .opacity(titleOpacity)
        }
        .frame(width: width, alignment: .top)
        // One element per card, framed to the card and its title row, with
        // Open and Close actions (no nested images or buttons).
        .accessibilityRepresentation {
            Button("\(title), tab", action: onOpen)
                .accessibilityAction(named: "Open", onOpen)
                .accessibilityAction(named: "Close", onClose)
        }
    }
}

/// Tab overview: wallpaper, 2-column grid, top controls and the bottom bar
/// (+, "N Tabs", Done).
struct TabOverview<Source: TabsDataSource>: View {
    var source: Source
    var layout: OverviewLayout
    /// 0 while the page is full screen, 1 with the grid at rest.
    var shown: Double
    var chrome: CardChrome
    /// Swipe-to-close offsets (shared with the live page layer).
    var swipes: CardSwipeState
    /// Card hidden while the zooming page stands in for it.
    var hiddenTabId: String?
    /// Cards take taps (the grid is settled).
    var gridInteractive: Bool
    /// Cards take swipes (settled, or a zoom heading to the grid: Safari
    /// closes a card swiped during the zoom-out). Taps wait for the grid.
    var swipeInteractive = false
    /// The bottom bar takes taps (settled, or a zoom heading here: Done reverses it).
    var controlsInteractive: Bool
    /// Scroll offset and content origin, written on every scroll frame
    /// (never read by this body, so scrolling does not rebuild the cards).
    var scroll: GridScrollTracker
    @Binding var position: ScrollPosition
    var onSelect: (String) -> Void
    /// Closes the card's tab; false when refused (it stays).
    var onClose: (String) async -> Bool
    var onNewTab: (TabsKitNewTabOption) -> Void
    var onDone: () -> Void
    var onCloseAll: () -> Void
    /// A tab being created with (+): its card is already in the grid (at
    /// index tabs.count) so the zoom can land on its real frame.
    var pending: TabsKitNewTabOption?
    /// The grid started (true) or stopped (false) scrolling.
    var onScrolling: (Bool) -> Void = { _ in }
    /// A card tapped during the zoom to the grid (open it once settled).
    var onQueueSelect: (String) -> Void = { _ in }
    /// The card a long press owns changed (nil when released).
    var onPressChanged: (String?) -> Void = { _ in }

    @Environment(\.tabsKitTheme) private var theme
    /// A long-pressed card: lifted, the grid dimmed, its menu showing.
    @State private var pressed: String?
    @State private var pressStart: CGPoint = .zero
    /// A long-pressed card being dragged to another slot.
    @State private var reorder: CardReorder?

    private struct CardReorder: Equatable {
        let id: String
        let grab: CGPoint
        var point: CGPoint
    }

    var body: some View {
        let tabs = source.tabs
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [theme.colors.overviewTop, theme.colors.overviewBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: layout.size.width, height: layout.contentHeight)
                    // The listed cards, then any swiped card still flying off
                    // after its tab left the list (the same view keeps going).
                    ForEach(gridCards(), id: \.tab.id) { card in gridCardView(card) }
                    if let id = pressed, let index = tabs.firstIndex(where: { $0.id == id }) {
                        // The grid dims behind the lifted card; a tap outside closes the menu.
                        Color.black.opacity(CardMenuStyle.dim)
                            .frame(width: layout.size.width, height: max(layout.contentHeight, layout.size.height))
                            .contentShape(.rect)
                            .onTapGesture { closeMenu() }
                            .zIndex(15_000)
                            .transition(.opacity)
                        cardMenuPanel(tabs[index], card: layout.card(index))
                            .zIndex(17_000)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                    }
                    if let pending {
                        let r = layout.card(tabs.count)
                        TabCard(title: pending.title, systemImage: pending.systemImage, pageSize: layout.size, width: r.width, height: r.height,
                                radius: layout.cardRadius, showsClose: false, closeOpacity: chrome.closeOpacity,
                                titleOpacity: chrome.titleOpacity, titleOffset: chrome.titleOffset, onClose: {}) {
                            theme.colors.pageBackground
                        }
                        .offset(x: r.minX, y: r.minY)
                        .zIndex(Double(tabs.count))
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: layout.size.width, height: layout.contentHeight, alignment: .topLeading)
                // The grid reflows when a tab leaves (the data source removes
                // it once its close succeeded).
                .animation(theme.motion.resolve(theme.motion.reflow), value: tabs.map(\.id))
                .onChange(of: tabs.map(\.id)) { _, ids in
                    if let p = pressed, !ids.contains(p) { pressed = nil }
                }
                .onChange(of: gridInteractive) { _, _ in
                    pressed = nil
                    reorder = nil
                }
                .onChange(of: pressed ?? reorder?.id) { _, owner in onPressChanged(owner) }
                .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(TabsScreenSpace.name)).origin }) { [scroll] origin in
                    if scroll.contentOrigin != origin { scroll.contentOrigin = origin }
                }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { [scroll] _, y in
                if scroll.offset != y { scroll.offset = y }
            }
            .onScrollPhaseChange { _, phase in onScrolling(phase.isScrolling) }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .scaleEffect(1.06 - 0.06 * shown)
            .blur(radius: 10 * (1 - shown))
            .allowsHitTesting(gridInteractive || swipeInteractive)

            // Glass ignores inherited opacity; keep hidden controls out of
            // the hierarchy instead.
            if shown > 0 {
                topControls
                    .opacity(shown)
                    .allowsHitTesting(gridInteractive)
                bottomBar(count: tabs.count)
                    .opacity(shown)
                    .allowsHitTesting(controlsInteractive)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    /// Safari's card menu: the source's groups (Copy Link, Duplicate Tab...),
    /// then Close Tab and Close Other Tabs.
    private struct GridCard {
        let tab: TabsKitTab
        let index: Int
        let departed: DepartingCard?
    }

    private func gridCards() -> [GridCard] {
        let tabs = source.tabs
        var cards = tabs.enumerated().map { GridCard(tab: $0.element, index: $0.offset, departed: nil) }
        let listed = Set(tabs.map(\.id))
        for d in swipes.departing where !listed.contains(d.id) {
            cards.append(GridCard(tab: d.tab, index: tabs.count, departed: d))
        }
        return cards
    }

    /// One grid card with its tap, long press and swipe.
    @ViewBuilder private func gridCardView(_ card: GridCard) -> some View {
        let tab = card.tab, index = card.index
        let r = card.departed?.rect ?? layout.card(index)
        let copy = { DepartingCard(id: tab.id, tab: tab, rect: r) }
        let lifted = pressed == tab.id || reorder?.id == tab.id
        TabCard(title: tab.title, systemImage: tab.systemImage, pageSize: layout.size, width: r.width, height: r.height,
                radius: layout.cardRadius, showsClose: true, closeOpacity: chrome.closeOpacity,
                titleOpacity: chrome.titleOpacity, titleOffset: chrome.titleOffset,
                contentHidden: tab.id == hiddenTabId, onOpen: { onSelect(tab.id) },
                onClose: { Task { _ = await onClose(tab.id) } }) {
            source.card(for: tab)
        }
        .contentShape(.rect)
        // During the zoom to the grid a tap is kept and opens the card once
        // the grid has settled (Safari queues it).
        .onTapGesture { if gridInteractive { onSelect(tab.id) } else if swipeInteractive { onQueueSelect(tab.id) } }
        // Long press: the card menu; moving the finger then drags the card
        // to another slot. A plain recogniser: the system context menu held
        // the swipe back for about 450 ms.
        .gesture(CardLongPressGesture { phase in press(phase, tab: tab, rect: r) })
        // Swipe left to close (CardSwipe).
        .gesture(CardSwipeGesture { phase in
            // The card the zoom is landing on stays put.
            guard gridInteractive || tab.id != hiddenTabId else { return }
            let rm = UIAccessibility.isReduceMotionEnabled
            // A long press owns the touch (menu or reorder): the swipe never
            // moves the card, and its release can never close it.
            guard CardGestures.swipeAllowed(card: tab.id, pressed: pressed, reordering: reorder?.id) else {
                if swipes.isRaised(tab.id), !swipes.isDeparting(tab.id) { swipes.cancel(tab.id, reduceMotion: rm) }
                return
            }
            switch phase {
            case .changed(let dx): swipes.track(tab.id, translation: dx, reduceMotion: rm)
            case .ended(_, let v):
                swipes.release(tab.id, velocity: v, card: r, reduceMotion: rm, departing: copy) {
                    let closed = await onClose(tab.id)
                    // Safari opens the last tab when a swipe leaves only one.
                    if closed, source.tabs.count == 1, let last = source.tabs.first { onSelect(last.id) }
                    return closed
                }
            case .cancelled: swipes.cancel(tab.id, reduceMotion: rm)
            }
        })
        .opacity(swipes.opacity(tab.id))
        // Lifted about the card's centre while swiped (× 1.093) or long
        // pressed (× 1.06).
        .scaleEffect(lifted ? CardMenuStyle.lift : swipes.scale(tab.id), anchor: UnitPoint(x: 0.5, y: r.height / 2 / max(1, r.height + 25)))
        // Explicit stacking in grid order: cards crossing in a reflow keep
        // their order.
        .zIndex(swipes.isDeparting(tab.id) ? 20_000 : lifted ? 16_000 : swipes.isRaised(tab.id) ? 10_000 : Double(index))
        .offset(cardOffset(tab.id, rect: r))
        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.9))))
    }

    private func cardOffset(_ id: String, rect r: CGRect) -> CGSize {
        if let drag = reorder, drag.id == id {
            return CGSize(width: drag.point.x - drag.grab.x, height: drag.point.y - drag.grab.y)
        }
        return CGSize(width: r.minX + swipes.offset(id), height: r.minY)
    }

    private func contentPoint(_ p: CGPoint) -> CGPoint {
        let o = scroll.contentOrigin ?? .zero
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    private func closeMenu() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { pressed = nil }
    }

    private func press(_ phase: CardPressPhase, tab: TabsKitTab, rect r: CGRect) {
        switch phase {
        case .began(let p):
            guard gridInteractive, !swipes.isRaised(tab.id) else { return }
            pressStart = p
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pressed = tab.id }
        case .changed(let p):
            guard pressed == tab.id || reorder?.id == tab.id, source.supportsReordering || reorder != nil else { return }
            if reorder == nil {
                guard hypot(p.x - pressStart.x, p.y - pressStart.y) > 10 else { return }
                let c = contentPoint(p)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { pressed = nil }
                reorder = CardReorder(id: tab.id, grab: CGPoint(x: c.x - r.minX, y: c.y - r.minY), point: c)
            }
            guard var drag = reorder else { return }
            drag.point = contentPoint(p)
            reorder = drag
            let center = CGPoint(x: drag.point.x - drag.grab.x + r.width / 2, y: drag.point.y - drag.grab.y + r.height / 2)
            if let slot = layout.slot(at: center), slot < source.tabs.count, source.tabs.firstIndex(where: { $0.id == tab.id }) != slot {
                withAnimation(theme.motion.resolve(theme.motion.reflow)) { source.moveTab(tab.id, to: slot) }
            }
        case .ended, .cancelled:
            if reorder?.id == tab.id {
                withAnimation(theme.motion.resolve(theme.motion.reflow)) { reorder = nil }
            }
        }
    }

    /// The menu items: the source's groups, then Close Tab and Close Other Tabs.
    private func menuGroups(_ tab: TabsKitTab) -> [[TabsKitMenuItem]] {
        var groups = source.cardMenu(for: tab)
        var close = [TabsKitMenuItem(title: "Close Tab", systemImage: "xmark", isDestructive: true) { [onClose] in
            Task { _ = await onClose(tab.id) }
        }]
        if source.tabs.count > 1 {
            let others = source.tabs.map(\.id).filter { $0 != tab.id }
            close.append(TabsKitMenuItem(title: "Close Other Tabs", systemImage: "xmark.square", isDestructive: true) { [onClose] in
                for other in others { Task { _ = await onClose(other) } }
            })
        }
        groups.append(close)
        return groups
    }

    /// The glass menu under the lifted card (over it when there is no room below).
    @ViewBuilder private func cardMenuPanel(_ tab: TabsKitTab, card: CGRect) -> some View {
        let groups = menuGroups(tab)
        let rows = groups.reduce(0) { $0 + $1.count }
        let height = CGFloat(rows) * CardMenuStyle.row + CGFloat(max(0, groups.count - 1)) * 8
        let width = CardMenuStyle.width
        let below = card.maxY + theme.metrics.titleRow + 12
        let screenBottom = (scroll.contentOrigin.map { -$0.y } ?? 0) + layout.size.height - layout.safeBottom - 60
        let y = below + height <= screenBottom ? below : max(8, card.minY - 12 - height)
        let x = min(max(16, card.midX - width / 2), layout.size.width - 16 - width)
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { g, group in
                if g > 0 { Rectangle().fill(theme.colors.label.opacity(0.08)).frame(height: 8) }
                ForEach(group) { item in
                    Button {
                        closeMenu()
                        item.action()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.systemImage).frame(width: 22)
                            Text(item.title)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 17))
                        .foregroundStyle(item.isDestructive ? Color.red : theme.colors.label)
                        .padding(.horizontal, 16)
                        .frame(height: CardMenuStyle.row)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isEnabled)
                }
            }
        }
        .frame(width: width)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .offset(x: x, y: y)
    }

    private var topControls: some View {
        let d = theme.metrics.overviewTopControl
        let y = layout.safeTop + 4 + d / 2
        return ZStack(alignment: .topLeading) {
            Menu {
                Button("Close All Tabs", systemImage: "xmark", role: .destructive, action: onCloseAll)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.colors.label)
                    .frame(width: d, height: d)
                    .contentShape(.circle)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .position(x: layout.size.width - 20 - d / 2, y: y)
            .accessibilityLabel("More")
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func bottomBar(count: Int) -> some View {
        let bar = layout.barRect
        let options = source.newTabOptions
        // One glass container for the bar: the controls share one backdrop
        // capture, re-rendered on every scroll frame (spacing 0: they never
        // blend into one shape).
        return GlassEffectContainer(spacing: 0) {
        ZStack(alignment: .topLeading) {
            Group {
                if options.count > 1 {
                    // Several kinds: (+) asks which.
                    Menu {
                        ForEach(options) { option in
                            Button(option.title, systemImage: option.systemImage) { onNewTab(option) }
                        }
                    } label: {
                        plusGlyph
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                } else {
                    Button { if let first = options.first { onNewTab(first) } } label: { plusGlyph }
                        .buttonStyle(.plain)
                        .disabled(options.isEmpty)
                }
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .position(x: 38 + 24, y: bar.midY)
            .accessibilityLabel("New Tab")

            // One glass shape per control (nested glass reads as a double background).
            Text(count == 1 ? "1 Tab" : "\(count) Tabs")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.colors.label)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .glassEffect(.regular, in: .capsule)
                .position(x: layout.size.width / 2, y: bar.midY)
                // Safari swaps the count at once (no crossfade).
                .contentTransition(.identity)
                .transaction { $0.animation = nil }

            Button(action: onDone) {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(theme.colors.accent).interactive(), in: .circle)
            .position(x: layout.size.width - 38 - 24, y: bar.midY)
            .accessibilityLabel("Done")
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        }
    }

    private var plusGlyph: some View {
        Image(systemName: "plus").font(.system(size: 22, weight: .regular))
            .foregroundStyle(theme.colors.label)
            .frame(width: 48, height: 48).contentShape(.circle)
    }
}

/// Safari's long press on a grid card: the card lifts to × 1.06 and the
/// other cards dim.
struct CardMenuStyle: Equatable, Sendable {
    static let lift: CGFloat = 1.06
    static let dim = 0.35
    static let width: CGFloat = 250
    static let row: CGFloat = 44
}
#endif
