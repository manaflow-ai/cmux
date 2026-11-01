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
            // A hidden card's content is not built: the zooming page (or the
            // live page on its card) draws it, and a hidden chat card kept
            // re-rendering every streamed token under the page.
            ZStack {
                if !contentHidden { ScaledContent(pageSize: pageSize) { content.environment(\.tabsKitCardPageSize, pageSize) } }
            }
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                // A stretchable shadow image: `.shadow` on the clipped card
                // cost an offscreen pass per card on every scroll frame.
                .background { CardShadow(radius: radius) }
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
        // The close button is its own "Close" element after the card, as
        // Safari's (it was folded into the card's element).
        .overlay(alignment: .topTrailing) {
            if showsClose {
                Button(action: onClose) {
                    CardCloseGlyph()
                        .padding(4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .opacity(closeOpacity * (contentHidden ? 0 : 1))
                .allowsHitTesting(closeOpacity > 0.5 && !contentHidden)
                .accessibilityLabel("Close")
                .accessibilityHint(Text("Closes \(title)"))
                .accessibilityHidden(closeOpacity < 0.5)
                .accessibilitySortPriority(-1)
            }
        }
        .accessibilityElement(children: .contain)
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
    /// A card dragged from its lifted context-menu preview to another slot.
    @State private var dragging: String?
    /// Select Tabs mode and its selection.
    @State private var selecting = false
    @State private var selection = TabSelection()
    /// Which cards are in the tree (`CardResidency`).
    @State private var residency = CardResidency()
    /// The grid is on screen (opening, shown or closing).
    var isVisible = true
    /// The grid is at rest (no zoom running): cards off screen are built
    /// ahead only then, so the zoom's frames build nothing but what it shows.
    var isSettled = true

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
                .animation(reflowAnimation, value: tabs.map(\.id))
                // Long press, then drag from the lifted preview: the card moves
                // to the slot under the finger (Safari).
                .onDrop(of: [.text], delegate: CardReorderDrop(layout: layout, ids: tabs.map(\.id), pinned: layout.pinned,
                                                            canMove: source.supportsReordering, dragging: $dragging,
                                                            move: { source.moveTab($0, to: $1) }))
                .onChange(of: tabs.map(\.id)) { _, ids in
                    // A fling's count is the list's now.
                    if swipes.reflowCue == 0, swipes.countHold == max(1, ids.count) { swipes.countHold = nil }
                    if let d = dragging, !ids.contains(d) { dragging = nil }
                    selection.retain(ids)
                }
                .onChange(of: gridInteractive) { _, interactive in
                    dragging = nil
                    if !interactive { endSelecting() }
                }
                .onChange(of: dragging) { _, owner in onPressChanged(owner) }
                .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(TabsScreenSpace.name)).origin }) { [scroll] origin in
                    if scroll.contentOrigin != origin { scroll.contentOrigin = origin }
                }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { [scroll, residency] _, y in
                if scroll.offset != y { scroll.offset = y }
                // Builds and releases cards as they near or leave the
                // screen, without re-running this body.
                residency.scrolled(to: y)
            }
            .onScrollPhaseChange { _, phase in
                residency.setScrolling(phase.isScrolling)
                onScrolling(phase.isScrolling)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            // Safari's top edge: cards scrolled under the status bar and the
            // top controls blur and fade into the background.
            .overlay(alignment: .top) {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                        .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                    LinearGradient(colors: [theme.colors.overviewTop, theme.colors.overviewTop.opacity(0.6), .clear],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(height: layout.safeTop + 52)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .scaleEffect(1.06 - 0.06 * shown)
            .blur(radius: 10 * (1 - shown))
            .allowsHitTesting(gridInteractive || swipeInteractive)

            // Glass ignores inherited opacity, so the hidden controls are
            // parked off screen instead of fading: building their glass in
            // the zoom's first frames made those frames late. They leave the
            // hierarchy only on a settled page (no zoom heading to the grid):
            // parked there, `accessibilityHidden` did not keep controls drawn
            // in glass or as menus out of the page's accessibility tree (full
            // verify 2026-10-19 D7, T-TABS-14: "More", "New", "Done").
            let parked = shown <= 0
            if !parked || controlsInteractive || swipeInteractive || gridInteractive {
            Group {
                Group {
                    if selecting { selectControls } else { topControls }
                }
                    .opacity(shown)
                    .allowsHitTesting(gridInteractive)
                bottomBar(count: tabs.count)
                    .opacity(shown)
                    .allowsHitTesting(controlsInteractive)
            }
            .offset(y: parked ? layout.size.height * 2 : 0)
            .accessibilityHidden(parked)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .onChange(of: ResidencyInputs(ids: tabs.map(\.id), layout: layout), initial: true) { _, inputs in
            residency.update(ids: inputs.ids, layout: inputs.layout)
        }
        .onChange(of: isVisible, initial: true) { _, visible in residency.setVisible(visible) }
        .onChange(of: isSettled, initial: true) { _, settled in residency.setSettled(settled) }
        // The grid rests (settled, still for a few frames, nothing left to build):
        // the source may draw costly cards now, never in a frame the grid
        // itself needs.
        .onAppear { [residency, source] in
            residency.idleSink = { [weak source] idle in source?.overviewIdleChanged(idle) }
        }
    }

    private struct ResidencyInputs: Equatable {
        var ids: [String]
        var layout: OverviewLayout
    }

    /// Safari's card menu: the source's groups (Copy Link, Duplicate Tab...),
    /// then Close Tab and Close Other Tabs.
    private struct GridCard {
        let tab: TabsKitTab
        let index: Int
        let departed: DepartingCard?
    }

    /// The listed cards (each in the tree only while `CardResidency` has
    /// it built), then cards still flying off after a swipe.
    private func gridCards() -> [GridCard] {
        let tabs = source.tabs
        var cards = tabs.enumerated().map { GridCard(tab: $0.element, index: $0.offset, departed: nil) }
        let listed = Set(tabs.map(\.id))
        for d in swipes.departing where !listed.contains(d.id) {
            cards.append(GridCard(tab: d.tab, index: tabs.count, departed: d))
        }
        return cards
    }

    /// An unbuilt card's accessibility element, named as its built card is.
    private func standIn(_ tab: TabsKitTab, rect: CGRect, pinned: Bool) -> CardStandIn {
        CardStandIn(label: pinned ? "\(tab.title), Pinned" : "\(tab.title), tab", rect: rect,
                    open: { [onSelect] in onSelect(tab.id) },
                    close: pinned ? nil : { Task { _ = await closeTapped(tab.id) } })
    }

    /// A card kept built outside the band: a gesture or the zoom owns it.
    private func holds(_ id: String) -> Bool {
        id == hiddenTabId || id == dragging || id == swipes.menuCard || swipes.isRaised(id)
    }

    /// One grid card with its tap, long press and swipe; pinned tabs are
    /// capsules in the pinned area.
    // perf-hot: O(1) per card per grid body; cards off the keep band are not built tabs-grid-residency
    @ViewBuilder private func gridCardView(_ card: GridCard) -> some View {
        let id = card.tab.id
        if card.departed == nil, card.index < layout.pinned {
            ResidentCard(slot: residency.slot(id), held: holds(id),
                         standIn: standIn(card.tab, rect: layout.card(card.index), pinned: true)) { pinnedCardView(card.tab, index: card.index) }
                .zIndex(Double(card.index))
                .transition(.opacity)
        } else {
            ResidentCard(slot: residency.slot(id), held: card.departed != nil || holds(id),
                         standIn: standIn(card.tab, rect: card.departed?.rect ?? layout.card(card.index), pinned: false)) { tabCardView(card) }
                // Explicit stacking in grid order: cards crossing in a reflow
                // keep their order.
                .zIndex(swipes.isDeparting(id) ? 20_000 : swipes.isRaised(id) ? 10_000 : Double(card.index))
                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.9))))
        }
    }

    @ViewBuilder private func tabCardView(_ card: GridCard) -> some View {
        let tab = card.tab, index = card.index
        let r = card.departed?.rect ?? layout.card(index)
        let copy = { DepartingCard(id: tab.id, tab: tab, rect: r) }
        TabCard(title: tab.title, systemImage: tab.systemImage, pageSize: layout.size, width: r.width, height: r.height,
                radius: layout.cardRadius, showsClose: !selecting, closeOpacity: chrome.closeOpacity,
                titleOpacity: chrome.titleOpacity, titleOffset: chrome.titleOffset,
                contentHidden: tab.id == hiddenTabId, onOpen: { onSelect(tab.id) },
                onClose: { Task { _ = await closeTapped(tab.id) } }) {
            source.card(for: tab)
                .offset(y: -source.cardContentOffset(for: tab.id, visibleHeight: layout.cardPageHeight))
        }
        // Under its lifted long-press preview, and while it is dragged to
        // another slot (the dragged card is the card), the card is hidden.
        .opacity(swipes.menuCard == tab.id || dragging == tab.id ? 0 : 1)
        .overlay(alignment: .topLeading) {
            if selecting { SelectionMark(selected: selection.contains(tab.id), width: r.width, height: r.height, radius: layout.cardRadius) }
        }
        // Tap, swipe, the system context menu (the card lifts into its
        // preview) and a drag from the lifted preview, in UIKit.
        .overlay(alignment: .topLeading) {
            CardInteraction(
                card: r.size, radius: layout.cardRadius,
                passThrough: selecting ? nil : CGRect(x: r.width - 30, y: 0, width: 30, height: 30),
                menu: { selecting ? [] : menuSections(tab) },
                preview: { scale in
                    AnyView(CardMenuPreview(scale: scale, card: r.size, radius: layout.cardRadius) {
                        source.card(for: tab)
                            .offset(y: -source.cardContentOffset(for: tab.id, visibleHeight: layout.cardPageHeight))
                    }
                        .environment(\.tabsKitTheme, theme))
                },
                dragKey: selecting || !source.supportsReordering ? nil : tab.id,
                onMenu: { open in swipes.menuChanged(tab.id, open) },
                onTap: {
                    if selecting { selection.toggle(tab.id) }
                    else if gridInteractive { onSelect(tab.id) } else if swipeInteractive { onQueueSelect(tab.id) }
                },
                onPan: { phase in
                    guard gridInteractive || tab.id != hiddenTabId, !selecting else { return }
                    let rm = UIAccessibility.isReduceMotionEnabled
                    guard CardGestures.swipeAllowed(card: tab.id, pressed: nil, reordering: dragging) else {
                        if swipes.isRaised(tab.id), !swipes.isDeparting(tab.id) { swipes.cancel(tab.id, reduceMotion: rm) }
                        return
                    }
                    switch phase {
                    case .changed(let dx):
                        swipes.track(tab.id, translation: dx, reduceMotion: rm, cardWidth: r.width,
                                     onFling: { swipes.countHold = $0 ? max(1, source.tabs.count - 1) : nil })
                    case .ended(_, let v):
                        swipes.release(tab.id, velocity: v, card: r, reduceMotion: rm, departing: copy,
                                       onCommit: { swipes.countHold = max(1, source.tabs.count - 1) }) {
                            let closed = await onClose(tab.id)
                            // Safari opens the last tab when a swipe leaves only one.
                            if closed, source.tabs.count == 1, let last = source.tabs.first { onSelect(last.id) }
                            return closed
                        }
                    case .cancelled: swipes.cancel(tab.id, reduceMotion: rm)
                    }
                },
                onDragStart: { dragging = tab.id },
                onDragEnd: { dragging = nil })
            .frame(width: r.width, height: r.height + theme.metrics.titleRow)
        }
        .opacity(swipes.opacity(tab.id))
        // Lifted about the card's centre while swiped (× 1.093).
        .scaleEffect(swipes.scale(tab.id), anchor: UnitPoint(x: 0.5, y: r.height / 2 / max(1, r.height + 25)))
        .offset(x: r.minX + swipes.offset(tab.id), y: r.minY)
    }

    @ViewBuilder private func pinnedCardView(_ tab: TabsKitTab, index: Int) -> some View {
        let r = layout.card(index)
        PinnedCard(title: tab.title, systemImage: tab.systemImage, width: r.width, height: r.height,
                   selected: selecting ? selection.contains(tab.id) : nil)
            .opacity(swipes.menuCard == tab.id ? 0 : 1)
            .overlay {
                CardInteraction(
                    card: r.size, radius: r.height / 2, passThrough: nil,
                    menu: { selecting ? [] : menuSections(tab) },
                    preview: { scale in
                        AnyView(PinnedCard(title: tab.title, systemImage: tab.systemImage, width: r.width * scale, height: r.height * scale, selected: nil)
                            .environment(\.tabsKitTheme, theme))
                    },
                    dragKey: nil,
                    onMenu: { open in swipes.menuChanged(tab.id, open) },
                    onTap: { if selecting { selection.toggle(tab.id) } else if gridInteractive { onSelect(tab.id) } },
                    onPan: { _ in }, onDragStart: {}, onDragEnd: {})
            }
            .offset(x: r.minX, y: r.minY)
    }

    /// Safari's card menu: Copy Link, Pin Tab, Duplicate Tab (the source's
    /// items, Pin after the first), Select Tabs, Close Tab, then Close Other
    /// Tabs after a separator. A pinned tab: the source's first item, Unpin
    /// Tab, Select Tabs, Close Tab. (Safari's Move Tab moves a tab to another
    /// tab group; the kit has no tab groups.)
    private func menuSections(_ tab: TabsKitTab) -> [[CardMenuEntry]] {
        let pinned = source.pinnedTabIDs.contains(tab.id)
        var own = source.cardMenu(for: tab).flatMap { $0 }.map { item in
            CardMenuEntry(title: item.title, symbol: item.systemImage, destructive: item.isDestructive) { item.action() }
        }
        if pinned { own = Array(own.prefix(1)) }
        var main = own
        if source.supportsPinning {
            let pin = pinned
                ? CardMenuEntry(title: "Unpin Tab", symbol: "pin.slash") { source.setPinned([tab.id], false) }
                : CardMenuEntry(title: "Pin Tab", symbol: "pin") { source.setPinned([tab.id], true) }
            main.insert(pin, at: min(1, main.count))
        }
        main.append(CardMenuEntry(title: "Select Tabs", symbol: "checkmark.circle") { beginSelecting(tab.id) })
        main.append(CardMenuEntry(title: "Close Tab", symbol: "xmark", destructive: true) { Task { _ = await closeTapped(tab.id) } })
        var sections = [main]
        if !pinned, source.tabs.count > 1 {
            let others = source.tabs.map(\.id).filter { $0 != tab.id && !source.pinnedTabIDs.contains($0) }
            sections.append([CardMenuEntry(title: "Close Other Tabs", symbol: "xmark", destructive: true) {
                for o in others { Task { _ = await onClose(o) } }
            }])
        }
        return sections
    }

    private func beginSelecting(_ id: String) {
        selection = TabSelection()
        selection.toggle(id)
        selecting = true
    }

    private func endSelecting() {
        selecting = false
        selection = TabSelection()
    }

    /// Select Tabs: Close (with a confirmation), More (Pin, Copy Links) and
    /// Done, with "N selected" over the grid.
    private var selectControls: some View {
        let d = theme.metrics.overviewTopControl
        let y = layout.safeTop + 4 + d / 2
        let keys = selection.keys(in: source.tabs.map(\.id))
        let links = source.links(for: keys)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Menu {
                    Button(selection.closeTitle, role: .destructive) {
                        endSelecting()
                        for k in keys { Task { _ = await onClose(k) } }
                    }
                } label: {
                    Text("Close").font(.system(size: 17)).padding(.horizontal, 12).frame(height: d).contentShape(.rect)
                }
                .disabled(selection.isEmpty)
                Menu {
                    if source.supportsPinning {
                        Button(selection.pinTitle, systemImage: "pin") {
                            source.setPinned(keys, true)
                            endSelecting()
                        }
                    }
                    if !links.isEmpty {
                        Button(selection.copyTitle, systemImage: "link") {
                            UIPasteboard.general.string = links.map(\.absoluteString).joined(separator: "\n")
                            endSelecting()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                        .frame(width: d, height: d).contentShape(.rect)
                }
                .disabled(selection.isEmpty)
                .accessibilityLabel("More")
            }
            .foregroundStyle(theme.colors.label)
            .padding(.horizontal, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
            .position(x: 20 + 70, y: y)
            Button { endSelecting() } label: {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: d, height: d).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(theme.colors.accent).interactive(), in: .circle)
            .position(x: layout.size.width - 20 - d / 2, y: y)
            .accessibilityLabel("Done")
            Text(selection.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.colors.label)
                .padding(.horizontal, 12).frame(height: 28)
                .glassEffect(.regular, in: .capsule)
                .position(x: layout.size.width / 2, y: layout.top + 14)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
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

    /// The grid's reflow: the theme's, or after a ✕ the same curve cued to
    /// time the count (`CardSwipeState.holdCountForTapClose`).
    private var reflowAnimation: Animation {
        let reflow = theme.motion.resolve(theme.motion.reflow)
        guard swipes.reflowCue != 0, reflow == Animation(SafariCurveAnimation(curve: .reflow)) else { return reflow }
        return .safari(.reflow, cue: swipes.reflowCue)
    }

    /// A card's ✕ (or the menu's Close Tab): the count waits for the reflow.
    private func closeTapped(_ id: TabsKitTab.ID) async -> Bool {
        if !UIAccessibility.isReduceMotionEnabled { swipes.holdCountForTapClose(max(1, source.tabs.count)) }
        return await onClose(id)
    }

    private func bottomBar(count: Int) -> some View {
        let bar = layout.barRect
        let options = source.newTabOptions
        // One glass container for the bar: the controls share one backdrop
        // capture, re-rendered on every scroll frame (spacing 0: they never
        // blend into one shape).
        return GlassEffectContainer(spacing: 0) {
        ZStack(alignment: .topLeading) {
            // Glass ignores inherited opacity: out of the hierarchy while selecting.
            if !selecting {
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
            // Several kinds make (+) a menu: "New", with a hint naming them.
            .accessibilityLabel(options.count > 1 ? "New" : "New Tab")
            .accessibilityHint(options.count > 1 ? "Shows " + options.map(\.title).joined(separator: " and ") : "")
            }

            // One glass shape per control (nested glass reads as a double background).
            TabCountLabel(swipes: swipes, count: count)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.colors.label)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .glassEffect(.regular, in: .capsule)
                .position(x: layout.size.width / 2, y: bar.midY)
                // Safari swaps the count at once (no crossfade).
                .contentTransition(.identity)
                .transaction { $0.animation = nil }

            if !selecting {
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

/// Safari's context-menu preview of a card: its content at `scale` (1: the
/// card lifts and UIKit grows it to Safari's 195.7 x 275), corner scaled too.
struct CardMenuPreview<Content: View>: View {
    var scale: CGFloat
    var card: CGSize
    var radius: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScaledContent(pageSize: CGSize(width: card.width * scale, height: card.height * scale)) { content }
            .frame(width: card.width * scale, height: card.height * scale, alignment: .top)
            .clipShape(.rect(cornerRadius: radius * scale, style: .continuous))
    }
}

/// Safari's pinned tab: a 30 pt capsule (177 x 30, black, icon, semibold
/// title, a pin in a 22 pt circle on the right).
struct PinnedCard: View {
    var title: String
    var systemImage: String
    var width: CGFloat
    var height: CGFloat
    var selected: Bool?
    @Environment(\.tabsKitTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 4)
            ZStack {
                Circle().fill(Color.white.opacity(0.12)).frame(width: 22, height: 22)
                Image(systemName: selected == true ? "checkmark" : "pin.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.leading, 9).padding(.trailing, 4)
        .frame(width: width, height: height)
        .background(Color.black, in: .capsule)
        .overlay { if selected == true { Capsule().strokeBorder(theme.colors.accent, lineWidth: 3).padding(-4) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), Pinned")
        .accessibilityAddTraits(.isButton)
    }
}

/// Select Tabs: a selected card gets an accent ring and a filled check;
/// the others an empty circle where the close button was.
struct SelectionMark: View {
    var selected: Bool
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    @Environment(\.tabsKitTheme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if selected {
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .strokeBorder(theme.colors.accent, lineWidth: 3)
                    .frame(width: width + 8, height: height + 8)
                    .offset(x: -4, y: -4)
            }
            Group {
                if selected {
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, theme.colors.accent)
                } else {
                    Image(systemName: "circle").foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.system(size: 22))
            .padding(4)
        }
        .frame(width: width, height: height, alignment: .topTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Reorders the grid while a card is dragged from its lifted preview.
struct CardReorderDrop: DropDelegate {
    let layout: OverviewLayout
    let ids: [String]
    let pinned: Int
    let canMove: Bool
    @Binding var dragging: String?
    let move: (String, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { canMove && dragging != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if canMove, let key = dragging, let slot = layout.slot(at: info.location), slot >= pinned, slot < ids.count, ids[slot] != key {
            move(key, slot)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
/// The bar's "N Tabs", apart from the grid's body: it follows a close's own
/// clock (`CardSwipeState.countHold`) without re-rendering the cards.
struct TabCountLabel: View {
    var swipes: CardSwipeState
    var count: Int

    var body: some View {
        let shown = swipes.countHold ?? count
        Text(shown == 1 ? "1 Tab" : "\(shown) Tabs")
    }
}
#endif
