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

    @Environment(\.tabsKitTheme) private var theme
    /// The card a long press lifted for a drag (also set by a long press
    /// that only opens the menu), and whether that drag is over the grid.
    @State private var dragging: String?
    @State private var dragOver = false

    var body: some View {
        let tabs = source.tabs
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [theme.colors.overviewTop, theme.colors.overviewBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: layout.size.width, height: layout.contentHeight)
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        let r = layout.card(index)
                        let copy = { DepartingCard(id: tab.id, tab: tab, rect: r) }
                        TabCard(title: tab.title, systemImage: tab.systemImage, pageSize: layout.size, width: r.width, height: r.height,
                                radius: layout.cardRadius, showsClose: true, closeOpacity: chrome.closeOpacity,
                                titleOpacity: chrome.titleOpacity, titleOffset: chrome.titleOffset,
                                contentHidden: tab.id == hiddenTabId, onOpen: { onSelect(tab.id) },
                                onClose: { Task { _ = await onClose(tab.id) } }) {
                            source.card(for: tab)
                        }
                        .contentShape(.rect)
                        .onTapGesture { if gridInteractive { onSelect(tab.id) } }
                        // Long press: the card menu (the card lifts); moving the
                        // finger instead drags the card to another slot.
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: layout.cardRadius))
                        .contextMenu { cardMenu(tab) }
                        .onDrag {
                            dragging = tab.id
                            return NSItemProvider(object: tab.id as NSString)
                        }
                        // Swipe left to close (CardSwipe).
                        .gesture(CardSwipeGesture { phase in
                            // The card the zoom is landing on stays put.
                            guard gridInteractive || tab.id != hiddenTabId else { return }
                            switch phase {
                            case .changed(let dx): swipes.track(tab.id, translation: dx, reduceMotion: UIAccessibility.isReduceMotionEnabled, copy: copy)
                            case .ended(_, let v):
                                swipes.release(tab.id, velocity: v, card: r, reduceMotion: UIAccessibility.isReduceMotionEnabled, departing: copy) {
                                    let closed = await onClose(tab.id)
                                    // Safari opens the last tab when a swipe leaves only one.
                                    if closed, source.tabs.count == 1, let last = source.tabs.first { onSelect(last.id) }
                                    return closed
                                }
                            case .cancelled: swipes.cancel(tab.id, reduceMotion: UIAccessibility.isReduceMotionEnabled)
                            }
                        })
                        .opacity(dragOver && dragging == tab.id ? 0 : swipes.opacity(tab.id))
                        // Lifted about the card's centre while dragged.
                        .scaleEffect(swipes.scale(tab.id), anchor: UnitPoint(x: 0.5, y: r.height / 2 / max(1, r.height + 25)))
                        // Explicit stacking in grid order (a swiped card on top):
                        // cards crossing in a reflow keep their order.
                        .zIndex(swipes.isRaised(tab.id) ? 10_000 : Double(index))
                        .offset(x: r.minX + swipes.offset(tab.id), y: r.minY)
                        // A swiped card's departing copy carries on off screen.
                        .transition(swipes.isDeparting(tab.id) ? .identity
                                    : .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                    ForEach(swipes.departing) { d in
                        TabCard(title: d.tab.title, systemImage: d.tab.systemImage, pageSize: layout.size, width: d.rect.width, height: d.rect.height,
                                radius: layout.cardRadius, showsClose: true, closeOpacity: chrome.closeOpacity,
                                titleOpacity: chrome.titleOpacity, titleOffset: chrome.titleOffset, onClose: {}) {
                            source.card(for: d.tab)
                        }
                        .opacity(swipes.departingOpacity(d.id))
                        .scaleEffect(swipes.scale(d.id), anchor: UnitPoint(x: 0.5, y: d.rect.height / 2 / max(1, d.rect.height + 25)))
                        .offset(x: d.rect.minX + swipes.offset(d.id), y: d.rect.minY)
                        .zIndex(20_000)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.identity)
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
                .onDrop(of: [.text], delegate: CardReorderDrop(layout: layout, ids: tabs.map(\.id), dragging: $dragging, over: $dragOver,
                                                            canMove: source.supportsReordering, move: { source.moveTab($0, to: $1) }))
                .onChange(of: tabs.map(\.id)) { _, ids in
                    if let d = dragging, !ids.contains(d) { dragging = nil; dragOver = false }
                }
                .onChange(of: gridInteractive) { _, _ in
                    dragging = nil
                    dragOver = false
                }
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
    @ViewBuilder private func cardMenu(_ tab: TabsKitTab) -> some View {
        ForEach(Array(source.cardMenu(for: tab).enumerated()), id: \.offset) { _, group in
            Section {
                ForEach(group) { item in
                    Button(item.title, systemImage: item.systemImage, role: item.isDestructive ? .destructive : nil) { item.action() }
                        .disabled(!item.isEnabled)
                }
            }
        }
        Section {
            Button("Close Tab", systemImage: "xmark", role: .destructive) { Task { _ = await onClose(tab.id) } }
            if source.tabs.count > 1 {
                Button("Close Other Tabs", systemImage: "xmark.square", role: .destructive) {
                    for other in source.tabs.map(\.id) where other != tab.id { Task { _ = await onClose(other) } }
                }
            }
        }
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
                .contentTransition(.numericText())
                .animation(.default, value: count)

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

/// Reorders the grid while a card is dragged: the card moves into the slot
/// under the finger (the others reflow), as in Safari.
struct CardReorderDrop: DropDelegate {
    let layout: OverviewLayout
    let ids: [String]
    @Binding var dragging: String?
    @Binding var over: Bool
    let canMove: Bool
    let move: (String, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { canMove && dragging != nil }

    func dropEntered(info: DropInfo) { if canMove, dragging != nil { over = true } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if canMove, let key = dragging, let slot = layout.slot(at: info.location), slot < ids.count, ids[slot] != key {
            move(key, slot)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        over = false
        return true
    }

    func dropExited(info: DropInfo) { over = false }
}
#endif
