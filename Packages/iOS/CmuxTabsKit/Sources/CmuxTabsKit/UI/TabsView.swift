#if os(iOS)
import SwiftUI
import UIKit

/// A Mobile Safari style tab experience for any content: the live page edge
/// to edge under a floating glass toolbar (collapsing pill, address
/// editing, page menu, back | forward, swipe between tabs), and a two-column
/// tab grid reached by the tabs button or a pinch, with the page zooming
/// into its card on one interruptible spring.
///
/// Give it a `TabsDataSource`; put it full screen (it ignores the safe
/// area and keyboard and lays out the toolbar itself).
public struct TabsView<Source: TabsDataSource>: View {
    let source: Source
    let isShowingOverview: Binding<Bool>?

    /// `isShowingOverview`: optional two-way binding to the tab grid. Set it
    /// to open or close the grid with the same zoom as the tabs button; the
    /// kit sets it when the user opens or closes the grid.
    public init(source: Source, isShowingOverview: Binding<Bool>? = nil) {
        self.source = source
        self.isShowingOverview = isShowingOverview
    }

    public var body: some View {
        // The outermost reader respects the keyboard: SwiftUI changes its
        // bottom inset inside the keyboard's own animation, so the address
        // field rides exactly with the keyboard (no notification lag).
        GeometryReader { withKeyboard in
            GeometryReader { outer in
                GeometryReader { full in
                    let kb = withKeyboard.safeAreaInsets.bottom
                    TabsScreen(source: source, isShowingOverview: isShowingOverview, size: full.size, safeTop: outer.safeAreaInsets.top,
                               safeBottom: outer.safeAreaInsets.bottom,
                               keyboard: kb > outer.safeAreaInsets.bottom + 1 ? kb : 0)
                }
                .ignoresSafeArea()
            }
            .ignoresSafeArea(.keyboard)
        }
    }
}

struct TabsScreen<Source: TabsDataSource>: View {
    let source: Source
    let isShowingOverview: Binding<Bool>?
    let size: CGSize
    let safeTop: CGFloat
    let safeBottom: CGFloat
    /// Software keyboard height from the screen bottom (0 when hidden).
    let keyboard: CGFloat

    @State private var chrome = ChromeState()
    /// Close All Tabs is waiting for the person's answer.
    @State private var confirmingCloseAll: CloseAllConfirmation?
    /// The page <-> grid transition (one interruptible progress value).
    @State private var zoomDriver = TabZoomDriver()
    /// Swipe-to-close offsets of the grid's cards.
    @State private var cardSwipes = CardSwipeState()
    /// Tab the zoom shows: the active tab, a tapped card, or a created tab.
    @State private var zoomTabId: String?
    /// The grid's scroll offset and content origin, written on every scroll
    /// frame. A reference (not `@State` values) so a scroll frame does not
    /// re-evaluate this screen and every card; only the views that read it
    /// (the zoom while it runs, the live page following its card) update.
    @State private var gridScroll = GridScrollTracker()
    private var gridContentOrigin: CGPoint? { gridScroll.contentOrigin }
    private var overviewScroll: CGFloat { gridScroll.offset }
    /// The active tab shown on the settled grid by its static card
    /// (`TabsDataSource.showStaticCard(for:)`).
    @State private var staticCardID: String?
    /// (+) pressed and the tab not created yet: the grid shows a placeholder
    /// card until the source lists the new tab (NewTabSlot).
    @State private var pendingNewTab: TabsKitNewTabOption?
    @State private var newTabSlot: NewTabSlot?
    /// A just-created tab opening from the screen's centre (Safari's new
    /// tab, not from its grid slot), and how.
    @State private var newTabZoomID: String?
    @State private var newTabZoom = NewTabZoom.plus
    /// A card tapped while the zoom headed to the grid: opened once it settles.
    @State private var queuedOpen: String?
    /// The active tab changed on the settled grid (its tab was closed): its
    /// grid card stands for it until the grid is left, so the live page
    /// never appears in the closed card's slot next to that card.
    @State private var activeChangedOnGrid = false
    /// The card a long press owns (lifted for its menu, or being dragged).
    @State private var pressedCard: String?
    /// On the settled grid the active card is drawn by the grid, not by the
    /// live page above it, whenever the grid must stack or animate it with
    /// the others: its tab changed, it is long-pressed, a card is being
    /// swiped (the flung card passed under the live page of its neighbour),
    /// or it is being closed (its removal fades and shrinks the card).
    private var gridDrawsActive: Bool {
        activeChangedOnGrid || (pressedCard != nil && pressedCard == activeID) || !cardSwipes.raisedCards.isEmpty
    }
    /// The pinch that drives the zoom (page -> grid, card -> page, or grabbing a running zoom).
    @State private var pinchSession = ZoomPinchSession()
    @State private var zoomPinchActive = false
    /// The insets the grid last had on screen: a page that hides a tab bar or
    /// the status bar has smaller ones, and a card revealed or laid out
    /// against them landed under the grid's bar once they came back
    /// (cmux-next real host, Back to Terminals: 63 pt short).
    @State private var gridTop: CGFloat = 0
    @State private var gridBottom: CGFloat = 0
    private var gridSafeTop: CGFloat { max(safeTop, gridTop) }
    private var gridSafeBottom: CGFloat { max(safeBottom, gridBottom) }
    @State private var overviewPosition = ScrollPosition(y: 0)
    @State private var menuExpanded = false
    @State private var menuContent = false
    @Environment(\.tabsKitTheme) private var theme

    private var fullRect: CGRect { CGRect(origin: .zero, size: size) }
    private var tabs: [TabsKitTab] { source.tabs }
    private var activeID: String? { source.activeTabID }
    private var activeTab: TabsKitTab? { activeID.flatMap { id in tabs.first { $0.id == id } } }
    private var activeIndex: Int? { activeID.flatMap { id in tabs.firstIndex { $0.id == id } } }

    private var zoomState: TabZoomState { zoomDriver.state }
    /// The grid is on screen (settled, opening, closing or pinched).
    private var overviewVisible: Bool { zoomState.showsOverview }
    /// 0 = page, 1 = grid, clamped (the spring may overshoot slightly).
    private var overviewShown: Double { min(1, max(0, zoomState.progress)) }
    /// Card titles and close buttons appear over the last fifth of the way.

    /// Leading tabs the source has pinned (they sit in the pinned area).
    private var pinnedCount: Int {
        let pins = source.pinnedTabIDs
        return pins.isEmpty ? 0 : (tabs.firstIndex { !pins.contains($0.id) } ?? tabs.count)
    }

    private var overviewLayout: OverviewLayout {
        OverviewLayout(size: size, safeTop: gridSafeTop, safeBottom: gridSafeBottom, count: newTabSlot?.cardCount(in: tabs.map(\.id)) ?? tabs.count,
                       pinned: pinnedCount)
    }

    private var toolbarLayout: ToolbarLayout {
        ToolbarLayout.make(metrics: theme.metrics, size: size, safeBottom: safeBottom, keyboard: keyboard, bar: chrome.bar,
                           editing: chrome.editing, splitBack: activeTab?.navigation.canGoForward == true, labelWidth: 69,
                           noBack: activeTab?.features.contains(.history) != true)
    }

    var body: some View {
        let layout = toolbarLayout
        ZStack(alignment: .topLeading) {
            overview
                // Close All Tabs asks first, as Safari does: every tab closes with no way back.
                .confirmationDialog(confirmingCloseAll?.confirmTitle ?? "", isPresented: Binding(
                    get: { confirmingCloseAll != nil }, set: { if !$0 { confirmingCloseAll = nil } }
                ), titleVisibility: .hidden, presenting: confirmingCloseAll) { confirmation in
                    Button(confirmation.confirmTitle, role: .destructive) { closeAll(confirmation.ids) }
                        .accessibilityIdentifier("tabs.closeAll.confirm")
                    Button("Cancel", role: .cancel) {}
                } message: { confirmation in
                    Text(confirmation.message)
                }

            if chrome.swiping {
                swipeNeighbor
            }

            pageLayer
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                // The grid's bottom bar stays on top of it: a page zooming into
                // a card that reaches the bar covered (+) and the count
                // (cmux-next re-audit 3 #11).
                .mask { BarCutout(bar: overviewLayout.barRect, shown: overviewShown) }

            if chrome.editing {
                source.editingBackground(addressEditing)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity.animation(.easeInOut(duration: 0.1).delay(0.03)))
            }

            if let tab = activeTab, zoomState.phase == .page, !chrome.swiping, !chrome.editing {
                // Above the toolbar, riding the keyboard while it is up.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    source.accessory(for: tab, context: contentContext)
                }
                .padding(.bottom, keyboard > 0 ? keyboard : size.height - layout.capsule.minY + 8)
                .frame(width: size.width, height: size.height)
            }

            // Out of the hierarchy on the settled grid (invisible there, and
            // accessibility tools list hidden views too).
            if zoomState.phase != .overview {
            TabsToolbar(chrome: chrome, tab: activeTab, size: size, safeBottom: safeBottom, keyboard: keyboard,
                        history: source.providesHistoryMenus ? { direction in
                            activeID.map { source.history(direction, for: $0) } ?? []
                        } : nil,
                        onHistoryItem: { item in if let id = activeID { source.goToHistoryItem(item, in: id) } },
                        onBack: { if let id = activeID { source.goBack(id) } },
                        onForward: { if let id = activeID { source.goForward(id) } },
                        onReload: { if let id = activeID { source.reloadOrStop(id) } },
                        onMenu: openMenu, onTabs: openOverview, onBeginEditing: beginEditing,
                        onEndEditing: { endEditing() }, onGo: go,
                        onSwipeChanged: swipeChanged, onSwipeEnded: swipeEnded,
                        onSwipeUpChanged: swipeUpChanged, onSwipeUpEnded: swipeUpEnded)
                .opacity(1 - overviewShown)
                // Usable on the page, and while a zoom heads back to the page
                // (the tabs button then reverses it).
                .allowsHitTesting(!chrome.menuOpen && (zoomState.pageInteractive || (zoomState.phase == .animating && !zoomState.headingToOverview)))
            }

            // Kept mounted (transparent) so the droplet starts growing on
            // the first frame after the tap instead of after its first layout.
            if !overviewVisible, let tab = activeTab {
                PageMenu(groups: source.pageMenu(for: tab),
                         origin: CGRect(x: layout.capsule.minX, y: layout.capsule.minY, width: theme.metrics.control, height: theme.metrics.control),
                         capsule: layout.capsule, topLimit: safeTop + 8, expanded: menuExpanded, contentVisible: menuContent,
                         onDismiss: closeMenu, onSelect: { item in
                             closeMenu()
                             item.action()
                         })
                    .opacity(chrome.menuOpen ? 1 : 0)
                    .allowsHitTesting(chrome.menuOpen)
                    .accessibilityHidden(!chrome.menuOpen)
            }

            if let notice = source.notice {
                Text(notice)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.colors.label)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    .padding(.horizontal, 24)
                    .padding(.top, safeTop + 8)
                    .frame(width: size.width, alignment: .top)
                    .onTapGesture { source.clearNotice() }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .task(id: notice) {
                        // Toast lifetime (a UI timeout, not synchronization).
                        try? await Task.sleep(for: .seconds(5))
                        if source.notice == notice { withAnimation { source.clearNotice() } }
                    }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named(TabsScreenSpace.name))
        .gesture(ZoomPinchGesture { handlePinch($0) })
        .onChange(of: size.width, initial: true) { _, w in zoomDriver.span = Double(w - overviewLayout.cardWidth) }
        .onChange(of: overviewVisible) { _, visible in source.overviewVisibilityChanged(visible) }
        .onChange(of: zoomState.phase == .overview ? safeTop : -1) { _, top in
            if top >= 0 { gridTop = top }
        }
        .onChange(of: zoomState.phase == .overview ? safeBottom : -1) { _, bottom in
            if bottom >= 0 { gridBottom = bottom }
        }
        .onChange(of: zoomState.phase == .overview) { _, onGrid in
            if onGrid {
                if let id = activeID, source.showStaticCard(for: id) { staticCardID = id }
            } else if let id = staticCardID {
                staticCardID = nil
                source.resumeLiveContent(id)
            }
        }
        // A tab that becomes active on the settled grid (the active one was
        // closed) is offered as a static card too, so it rides the reflow
        // with the other cards instead of appearing as the live page.
        .onChange(of: activeID) { old, new in
            if zoomState.phase == .overview { activeChangedOnGrid = true }
            guard zoomState.phase == .overview, let new, new != staticCardID else { return }
            if let old, old == staticCardID { source.resumeLiveContent(old) }
            staticCardID = source.showStaticCard(for: new) ? new : nil
        }
        .onAppear {
            zoomDriver.onSettle = { phase in
                if phase == .page {
                    zoomTabId = nil
                    queuedOpen = nil
                    chrome.expand(tap: true, theme)
                }
                if phase == .overview, let id = queuedOpen {
                    queuedOpen = nil
                    if source.tabs.contains(where: { $0.id == id }) { closeOverview(selecting: id) }
                }
            }
        }
        #if DEBUG
        // Screenshot harness: use the same action and menu as a toolbar tap.
        // The single delay is bounded and cancelled when this screen disappears.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-tabs-kit-demo-page-menu") else { return }
            do { try await Task.sleep(for: .milliseconds(1_500)) } catch { return }
            guard !Task.isCancelled, activeTab?.features.contains(.pageMenu) == true else { return }
            openMenu()
        }
        #endif
        .onChange(of: isShowingOverview?.wrappedValue, initial: true) { _, wanted in
            guard let wanted, wanted != zoomState.headingToOverview else { return }
            if wanted { openOverview() } else { closeOverview(selecting: activeID) }
        }
        .onChange(of: zoomState.phase) { _, phase in
            if phase == .page || phase == .overview { newTabZoomID = nil }
            if phase != .overview { activeChangedOnGrid = false }
        }
        .onAppear { cardSwipes.isListed = { id in source.tabs.contains { $0.id == id } } }
        .onChange(of: zoomState.headingToOverview) { _, heading in
            if let binding = isShowingOverview, binding.wrappedValue != heading { binding.wrappedValue = heading }
        }
        .onChange(of: tabs.isEmpty, initial: true) { _, empty in
            // Closing the last tab opens a fresh one, as Safari does.
            guard empty, let option = source.newTabOptions.first else { return }
            if !overviewVisible {
                Task { _ = await source.createTab(option) }
            } else if zoomState.phase == .overview {
                // Safari never leaves an empty grid: a fresh tab grows in
                // at once (0.95 -> 1 in about 200 ms).
                newTab(option, zoom: .lastTabClosed)
            }
        }
    }

    /// The tab grid, kept mounted (hidden) so opening it does not pay for
    /// building it on the first animation frame.
    @ViewBuilder private var overview: some View {
        // While it is hidden it is dormant: a change on the page (the toolbar collapsing, a
        // tab's title) does not re-run it (`DormantGate`).
        let hidden = zoomState.phase == .overview ? (staticCardID == activeID || gridDrawsActive ? nil : activeID) : (zoomTabId ?? activeID)
        DormantGate(dormant: !overviewVisible) {
        TabOverview(source: source, layout: overviewLayout, shown: overviewShown, chrome: zoomDriver.chrome, swipes: cardSwipes,
                    // On the settled grid the page layer draws the active
                    // tab's card live (the same view as the page); on the
                    // page and in the zoom it is the page itself, so its
                    // card is not built (a streaming chat's card re-rendered
                    // every token under the page).
                    hiddenTabId: hidden,
                    gridInteractive: zoomState.gridInteractive,
                    swipeInteractive: zoomState.phase == .animating && zoomState.headingToOverview,
                    controlsInteractive: overviewVisible && zoomState.headingToOverview,
                    scroll: gridScroll, position: $overviewPosition,
                    onSelect: { closeOverview(selecting: $0) },
                    onClose: { id in await closeFromGrid(id) },
                    onNewTab: newTabFromOverview,
                    onDone: { closeOverview(selecting: activeID) },
                    onCloseAll: { confirmingCloseAll = CloseAllConfirmation(ids: tabs.map(\.id)) },
                    pending: newTabSlot?.showsPlaceholder(in: tabs.map(\.id)) == true ? pendingNewTab : nil,
                    onScrolling: { source.overviewScrollingChanged($0) },
                    onQueueSelect: { queuedOpen = $0 },
                    onPressChanged: { pressedCard = $0 },
                    isVisible: overviewVisible,
                    isSettled: zoomState.phase == .overview)
        }
            .equatable()
            .opacity(overviewVisible ? 1 : 0)
            .allowsHitTesting(overviewVisible)
            .accessibilityHidden(!zoomState.gridInteractive)
    }

    // MARK: Page

    private var contentContext: TabsKitContentContext {
        let expanded = ToolbarLayout.make(metrics: theme.metrics, size: size, safeBottom: safeBottom, keyboard: 0, bar: .expanded,
                                          editing: false, splitBack: false, labelWidth: 69)
        let chrome = chrome, theme = theme
        return TabsKitContentContext(
            pageSize: size,
            safeAreaInsets: EdgeInsets(top: safeTop, leading: 0, bottom: max(0, size.height - expanded.capsule.minY + 8), trailing: 0),
            isInteractive: zoomState.pageInteractive && !chrome.swiping && !chrome.editing && !chrome.menuOpen,
            isZoomGestureActive: zoomPinchActive,
            isToolbarCollapsed: chrome.bar == .collapsed,
            onScroll: { dy in chrome.pageDragged(dy, theme) })
    }

    /// The active tab's live page. It stays at one place in the view tree
    /// in every phase: full screen on the page, the zoom's rect while it
    /// zooms, and its own card on the settled grid (live, following the
    /// grid's scroll). Only its scale, clip and offset change, so the
    /// client's view (a web view, a terminal) is never rebuilt or swapped,
    /// and the pixels on screen when a transition starts or ends are the
    /// same view's. It is laid out at full size and scaled into the rect.
    /// Until `isContentReady` says so, the tab's card covers it.
    @ViewBuilder private var pageLayer: some View {
        let phase = zoomState.phase
        let settled = phase == .page
        // On the settled grid the rect is in the grid's content coordinates
        // and `GridFollowOffset` moves it with the scroll.
        let g = settled ? (rect: fullRect, radius: chrome.swiping ? theme.metrics.screenRadius : 0)
            : phase == .overview ? (rect: activeCardContentRect.offsetBy(dx: activeID.map { cardSwipes.offset($0) } ?? 0, dy: 0),
                                    radius: overviewLayout.cardRadius) : zoomGeometry()
        let asCard = phase == .overview && staticCardID != nil && staticCardID == activeID
        let scale = size.width > 0 ? max(0.01, g.rect.width / size.width) : 1
        // The card's content anchor, moving with the zoom's scale.
        let anchor = overviewLayout.cardAnchorFraction(g.rect.width)
        let contentOffset = anchor > 0 ? anchor * (activeID.map { source.cardContentOffset(for: $0, visibleHeight: overviewLayout.cardPageHeight) } ?? 0) : 0
        let close = phase == .overview ? zoomDriver.chrome.closeOpacity
            : CardChrome.zoomCloseOpacity(progress: zoomState.progress, headingToOverview: phase == .interactive || zoomState.headingToOverview)
        ZStack(alignment: .topLeading) {
            theme.colors.pageBackground
            if let tab = activeTab {
                source.content(for: tab, context: contentContext)
                    .offset(y: -contentOffset)
                    .id(tab.id)
                // Until the content is ready, and while a new tab grows from
                // the screen's centre, its card stands in (a web view that
                // was just created draws nothing for about 300 ms).
                if !source.isContentReady(tab.id) || (newTabZoomID == tab.id && phase != .page) {
                    ScaledContent(pageSize: size) { source.card(for: tab).offset(y: -contentOffset).environment(\.tabsKitCardPageSize, size) }
                        .allowsHitTesting(false)
                        // Safari's new start page sharpens as it grows.
                        .blur(radius: newTabZoomID == tab.id && newTabZoom.blurs && phase != .page
                              ? 8 * min(1, max(0, zoomState.progress)) : 0)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: max(1, g.rect.width), height: max(1, g.rect.height), alignment: .topLeading)
        .clipShape(.rect(cornerRadius: g.radius, style: .continuous))
        .allowsHitTesting(settled && !chrome.swiping && !chrome.editing && !asCard)
        // The card's close button: it rides the zooming card's corner at full
        // size (fading in with progress) and is the active card's close
        // button on the settled grid (this layer covers that card).
        .overlay(alignment: .topTrailing) {
            // Not on a settled page: it is invisible there (opacity 0) and
            // its `accessibilityHidden` did not keep it out of the page's
            // accessibility tree (full verify 2026-10-19 D7, T-TABS-14).
            if zoomTabId != TabsScreenSpace.newTabMarker || phase == .overview, !settled, let id = activeID {
                Button {
                    if !UIAccessibility.isReduceMotionEnabled { cardSwipes.holdCountForTapClose(max(1, tabs.count)) }
                    Task { _ = await closeFromGrid(id) }
                } label: {
                    CardCloseGlyph().padding(4).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .opacity(settled ? 0 : close)
                .allowsHitTesting(phase == .overview && close > 0.5)
                .accessibilityHidden(phase != .overview)
                .accessibilityLabel("Close \(activeTab?.title ?? "")")
            }
        }
        .modifier(GridFollowOffset(origin: CGPoint(x: g.rect.minX + (chrome.swiping ? chrome.swipeOffset : 0), y: g.rect.minY),
                                   scroll: phase == .overview ? gridScroll : nil))
        // Hidden under its lifted long-press preview too.
        .opacity(asCard || (phase == .overview && gridDrawsActive) || (phase == .overview && activeID != nil && cardSwipes.menuCard == activeID) ? 0
                 : phase == .overview ? (activeID.map { cardSwipes.opacity($0) } ?? 1) : 1)
        // On the settled grid this is the active card: it moves with the
        // grid's reflow (a closed tab, the lone-tab layout) instead of jumping.
        // Not while a new tab is being added: its zoom from the screen's
        // centre then started from the reflow's in-flight offset (it grew
        // from the top-left corner, re-audit kit D5).
        .animation(phase == .overview && pendingNewTab == nil && !activeChangedOnGrid
                   ? theme.motion.resolve(theme.motion.reflow) : nil, value: tabs.map(\.id))
        .accessibilityHidden(!settled)
        .tabsKitStatusBarStyle(overviewVisible ? nil : activeTab?.statusBarStyle)
    }

    /// The active tab's card in the grid's content coordinates.
    private var activeCardContentRect: CGRect {
        let index = activeIndex ?? 0
        return OverviewLayout(size: size, safeTop: gridSafeTop, safeBottom: gridSafeBottom, count: max(tabs.count, index + 1), pinned: pinnedCount).card(index)
    }

    /// The tab beside the page during a toolbar swipe (its card content at
    /// full size), or an empty page past the last tab.
    @ViewBuilder private var swipeNeighbor: some View {
        let pitch = size.width + 12
        let offset = chrome.swipeOffset
        let progress = min(1, abs(offset) / pitch)
        let neighbor = swipeNeighborTab(for: offset)
        ZStack(alignment: .topLeading) {
            theme.colors.pageBackground
            if let neighbor {
                Group {
                    if case .tab(let tab) = neighbor {
                        ScaledContent(pageSize: size) { source.card(for: tab).environment(\.tabsKitCardPageSize, size) }
                    } else {
                        theme.colors.pageBackground
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(cornerRadius: theme.metrics.screenRadius, style: .continuous))
                .scaleEffect(0.93 + 0.07 * progress)
                .blur(radius: 6 * (1 - progress))
                .offset(x: offset + (offset < 0 ? pitch : -pitch))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private enum SwipeNeighbor {
        case tab(TabsKitTab)
        /// Past the last tab: a swipe there creates a tab.
        case newTab
    }

    private func swipeNeighborTab(for offset: CGFloat) -> SwipeNeighbor? {
        guard let index = activeIndex, offset != 0 else { return nil }
        let next = offset < 0 ? index + 1 : index - 1
        guard next >= 0 else { return nil }
        guard next < tabs.count else { return .newTab }
        return .tab(tabs[next])
    }

    // MARK: Zoom geometry

    /// The zooming tab's rect: full screen at progress 0, its card at 1,
    /// plus the pinch's free offset. The card end is read every frame, so it
    /// follows the grid's scroll offset and layout changes mid-flight.
    private func zoomGeometry() -> (rect: CGRect, radius: CGFloat) {
        let rect = zoomPath().rect(progress: zoomState.progress, offset: zoomState.offset)
        let q = min(1, max(0, CGFloat(zoomState.progress)))
        let m = theme.metrics
        return (rect, m.screenRadius + (overviewLayout.cardRadius - m.screenRadius) * q)
    }

    private func zoomPath() -> ZoomRectPath { ZoomRectPath(full: fullRect, card: zoomEndpoint()) }

    /// The zoom's card end: the card's frame in the grid's content converted
    /// to the screen through the grid's reported content origin, or the
    /// layout at the last known offset before the grid has reported.
    private func zoomEndpoint() -> CGRect {
        if let id = newTabZoomID, id == zoomTabId {
            guard newTabZoom.fromLoneSlot else { return newTabZoom.rect(in: fullRect) }
            let lone = OverviewLayout(size: size, safeTop: gridSafeTop, safeBottom: gridSafeBottom, count: 1)
            return lone.zoomEndpoint(0, contentOrigin: gridContentOrigin, fallbackOffset: overviewScroll)
        }
        let index: Int
        if zoomTabId == TabsScreenSpace.newTabMarker {
            index = tabs.count
        } else {
            index = zoomTabId.flatMap { id in tabs.firstIndex { $0.id == id } } ?? (activeIndex ?? 0)
        }
        let grid = OverviewLayout(size: size, safeTop: gridSafeTop, safeBottom: gridSafeBottom, count: max(tabs.count, index + 1), pinned: pinnedCount)
        return grid.zoomEndpoint(index, contentOrigin: gridContentOrigin, fallbackOffset: overviewScroll)
    }

    // MARK: Address editing

    private var addressEditing: TabsKitAddressEditing {
        TabsKitAddressEditing(query: chrome.editText, tab: activeTab, tabs: tabs, safeTop: safeTop,
                              onGo: { go($0) },
                              onSwitch: { id in
                                  source.activate(id)
                                  endEditing()
                              })
    }

    private func beginEditing() {
        guard !chrome.editing, activeTab?.features.contains(.addressEditing) ?? true else { return }
        if case .url(_, let text, _)? = activeTab?.address { chrome.editText = text } else { chrome.editText = "" }
        withAnimation(theme.motion.resolve(theme.motion.keyboard)) { chrome.editing = true }
    }

    private func endEditing() {
        guard chrome.editing else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(theme.motion.resolve(theme.motion.editEnd)) { chrome.editing = false }
    }

    private func go(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let id = activeID { source.navigate(id, to: trimmed) }
        endEditing()
    }

    // MARK: Page menu

    private func openMenu() {
        chrome.menuOpen = true
        menuExpanded = false
        menuContent = false
        withAnimation(theme.motion.resolve(theme.motion.menu)) { menuExpanded = true }
        withAnimation(.linear(duration: 0.12).delay(0.08)) { menuContent = true }
    }

    private func closeMenu() {
        withAnimation(.linear(duration: 0.1)) { menuContent = false }
        withAnimation(theme.motion.resolve(.spring(response: 0.3, dampingFraction: 0.9))) { menuExpanded = false } completion: {
            chrome.menuOpen = false
        }
    }

    // MARK: Tab grid

    /// Prepares the grid when it is about to appear from the page.
    private func prepareOverview(revealing index: Int, count: Int) {
        source.overviewWillAppear()
        // Safari: before the page shrinks into its card, the grid jumps (no
        // animation) so the card is fully on screen.
        let grid = OverviewLayout(size: size, safeTop: gridSafeTop, safeBottom: gridSafeBottom, count: count, pinned: pinnedCount)
        let offset = grid.offset(revealing: index, from: overviewScroll)
        if abs(offset - overviewScroll) > 0.5 {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { overviewPosition = ScrollPosition(y: offset) }
            // Until the scroll view reports it, the fallback endpoint uses it too.
            gridScroll.offset = offset
        }
    }

    /// Tabs button: page -> grid, or reverse a zoom that is heading to the page.
    private func openOverview() {
        if chrome.editing { endEditing() }
        if zoomState.phase == .page {
            zoomTabId = activeID
            prepareOverview(revealing: activeIndex ?? 0, count: tabs.count)
        }
        zoomDriver.go(toOverview: true)
    }

    /// Done or a card: grid -> page, or reverse a zoom heading to the grid.
    private func closeOverview(selecting tabId: String?) {
        guard overviewVisible else { return }
        if zoomState.phase == .overview {
            guard let tabId, tabs.contains(where: { $0.id == tabId }) else {
                if tabs.isEmpty {
                    if let option = source.newTabOptions.first { newTabFromOverview(option) }
                } else {
                    if activeID == nil, let first = tabs.first { source.activate(first.id) }
                    zoomTabId = activeID ?? tabs.first?.id
                    zoomDriver.go(toOverview: false)
                }
                return
            }
            if tabId != activeID { source.activate(tabId) }
            zoomTabId = tabId
        }
        zoomDriver.go(toOverview: false)
    }

    /// (+): the new tab's card goes into the grid at once (placeholder in
    /// its slot, until the source lists the tab, which then takes that slot
    /// in place); the zoom grows from that slot once the client created the
    /// tab, on Safari's new-tab spring. A refused create leaves the grid as
    /// it was.
    private func newTabFromOverview(_ option: TabsKitNewTabOption) { newTab(option, zoom: .plus) }

    private func newTab(_ option: TabsKitNewTabOption, zoom: NewTabZoom) {
        guard zoomState.phase == .overview, pendingNewTab == nil else { return }
        newTabZoom = zoom
        pendingNewTab = option
        newTabSlot = NewTabSlot(baseline: tabs.map(\.id))
        Task {
            let id = await source.createTab(option)
            withAnimation(theme.motion.resolve(theme.motion.reflow)) {
                pendingNewTab = nil
                newTabSlot = nil
            }
            guard let id else { return }
            openCreated(id)
        }
    }

    /// Grows a just-created tab from the screen's centre (grid only).
    private func openCreated(_ id: String) {
        guard zoomState.phase == .overview, tabs.contains(where: { $0.id == id }) else { return }
        if activeID != id { source.activate(id) }
        zoomTabId = id
        newTabZoomID = id
        zoomDriver.openNewTab(spring: newTabZoom.spring)
    }

    private func closeAll(_ ids: [String]) {
        Task { for id in ids { _ = await source.close(id) } }
        if let option = source.newTabOptions.first { newTabFromOverview(option) }
    }

    // MARK: Pinch

    /// Every pinch on the screen comes here. The decision is local and
    /// immediate: a pinch-in past 0.96 within 40 ms on the page (or any
    /// pinch-in when the content is not zoomed in), a pinch-out past 1.04 on
    /// a grid card, or any pinch while a zoom is running (it grabs the zoom
    /// where it is). Otherwise the pinch belongs to the page or the grid.
    private func handlePinch(_ sample: PinchSample) {
        let session = pinchSession
        switch sample.phase {
        case .began:
            session.reset()
            session.start = sample
            session.startRect = zoomGeometry().rect
            session.startedFromOverview = zoomState.phase == .overview
            decide(sample)
        case .changed:
            if session.start == nil {
                session.start = sample
                session.startRect = zoomGeometry().rect
                session.startedFromOverview = zoomState.phase == .overview
            }
            if session.decision == .pending { decide(sample) }
            if session.decision == .engaged { track(sample) }
        case .ended:
            if session.decision == .engaged { releasePinch(sample) }
            session.reset()
            zoomPinchActive = false
        }
    }

    private func decide(_ sample: PinchSample) {
        let session = pinchSession
        guard let start = session.start else { return }
        if session.movementStart == nil, abs(sample.scale - 1) > 0.005 { session.movementStart = sample.time }
        let moving = session.movementStart.map { sample.time - $0 } ?? 0
        switch zoomState.phase {
        case .animating, .interactive:
            engage()
        case .page:
            guard !chrome.editing, !chrome.menuOpen, !chrome.swiping, activeTab != nil else {
                session.decision = .rejected
                return
            }
            let atMinimumZoom = activeTab?.navigation.isZoomedIn != true
            if sample.scale <= ZoomPinchSession.engageIn, atMinimumZoom || moving <= ZoomPinchSession.decisionWindow {
                zoomTabId = activeID
                prepareOverview(revealing: activeIndex ?? 0, count: tabs.count)
                engage()
            } else if sample.scale > 1.005 || (!atMinimumZoom && moving > ZoomPinchSession.decisionWindow) {
                session.decision = .rejected
            }
        case .overview:
            guard let id = cardTab(at: start.centroid) else {
                session.decision = .rejected
                return
            }
            if sample.scale >= ZoomPinchSession.engageOut {
                // The page layer shows the active tab: make the pinched card's tab active.
                if id != activeID { source.activate(id) }
                zoomTabId = id
                session.startRect = zoomEndpoint()
                engage()
            } else if moving > ZoomPinchSession.decisionWindow || sample.scale < 1 {
                session.decision = .rejected
            }
        }
    }

    /// Starts tracking from the rect as presented when the fingers came
    /// down, under the start centroid.
    private func engage() {
        let session = pinchSession
        guard let start = session.start else { return }
        session.decision = .engaged
        session.tracker = PinchTracker(startRect: session.startRect, startCentroid: start.centroid)
        zoomDriver.beginInteraction()
        zoomPinchActive = true
    }

    private func track(_ sample: PinchSample) {
        let session = pinchSession
        guard let tracker = session.tracker else { return }
        let s = tracker.state(scale: sample.scale, centroid: sample.centroid, path: zoomPath())
        session.record(sample.time, s.progress, s.offset)
        let v = session.velocity()
        zoomDriver.updateInteraction(progress: s.progress, offset: s.offset, velocity: v.p, offsetVelocity: v.o)
    }

    private func releasePinch(_ sample: PinchSample) {
        let v = pinchSession.velocity()
        let toOverview = PinchTracker.releaseToOverview(progress: zoomState.progress, velocity: v.p,
                                                        startedFromOverview: pinchSession.startedFromOverview, path: zoomPath())
        zoomDriver.release(toOverview: toOverview)
    }

    /// The tab whose card is under `point` (screen coordinates).
    private func cardTab(at point: CGPoint) -> String? {
        let grid = overviewLayout
        for (i, tab) in tabs.enumerated()
        where grid.zoomEndpoint(i, contentOrigin: gridContentOrigin, fallbackOffset: overviewScroll).contains(point) {
            return tab.id
        }
        return nil
    }

    // MARK: Toolbar swipe

    /// Swipe up on the bar: the page shrinks toward its card with the finger.
    private func swipeUpChanged(_ up: CGFloat, _ velocity: CGFloat) {
        if zoomState.phase == .page {
            guard !chrome.swiping, activeID != nil else { return }
            zoomTabId = activeID
            prepareOverview(revealing: activeIndex ?? 0, count: tabs.count)
            // Safari's page follows its swipe-up curve in time (by finger travel
            // alone it dropped 98 pt in the first frame, cmux-next re-audit 3 D7).
            zoomDriver.startSwipeUp()
            return
        }
        // The finger turned back down: the swipe takes over interactively.
        if zoomState.playingSwipeUp, velocity < -50 { zoomDriver.beginInteraction() }
        guard zoomState.phase == .interactive else { return }
        zoomDriver.updateInteraction(progress: BarSwipe.progress(up: up), velocity: BarSwipe.velocity(up: up, velocity: velocity))
    }

    /// Release: on to the grid or back to the page, on the release spring.
    private func swipeUpEnded(_ up: CGFloat, _ velocity: CGFloat) {
        guard zoomState.phase == .interactive, !zoomPinchActive else { return }
        // Safari goes on to the grid along its own curve from where the
        // finger left the page; a swipe back down (or barely up) returns.
        if up > 24 && velocity >= 0 {
            zoomDriver.releaseOnSwipeUpCurve()
        } else {
            zoomDriver.endInteraction(velocity: BarSwipe.releaseVelocity(velocity), startedFromOverview: false)
        }
    }

    /// Closing from the grid: the active card is first handed to the grid
    /// (one update), so its removal fades and shrinks the card instead of
    /// the live page vanishing in one frame.
    private func closeFromGrid(_ id: String) async -> Bool {
        if id == activeID, zoomState.phase == .overview, !activeChangedOnGrid {
            activeChangedOnGrid = true
            await Task.yield()
        }
        return await source.close(id)
    }

    private func swipeChanged(_ dx: CGFloat) {
        if !chrome.swiping { chrome.swiping = true }
        let atFirst = (activeIndex ?? 0) == 0
        chrome.swipeOffset = dx > 0 && atFirst ? dx * 0.25 : dx
    }

    private func swipeEnded(_ dx: CGFloat, _ predicted: CGFloat) {
        let pitch = size.width + 12
        let index = activeIndex ?? 0
        let commit = abs(predicted) > size.width * 0.35 || abs(dx) > size.width * 0.5
        var target: CGFloat = 0
        var destination: String?? = nil  // .some(nil) = a new tab
        if commit, dx < 0 {
            target = -pitch
            destination = index + 1 < tabs.count ? .some(tabs[index + 1].id) : .some(nil)
        } else if commit, dx > 0, index > 0 {
            target = pitch
            destination = .some(tabs[index - 1].id)
        }
        withAnimation(theme.motion.resolve(theme.motion.swipe)) { chrome.swipeOffset = target } completion: {
            switch destination {
            case .some(.some(let id)):
                source.activate(id)
            case .some(.none):
                if let option = source.newTabOptions.first { Task { _ = await source.createTab(option) } }
            case .none:
                break
            }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                chrome.swipeOffset = 0
                chrome.swiping = false
            }
        }
    }
}
/// Holds back updates from the parent while the grid is hidden: two dormant
/// values compare equal, so SwiftUI keeps the grid as it was instead of
/// re-running it for every change on the page. Waking (the grid starting
/// to show) compares unequal and the grid gets the current values at once.
/// The grid's own observation (its tabs, its cards' content) still applies.
struct DormantGate<Content: View>: View, Equatable {
    let dormant: Bool
    @ViewBuilder let content: Content

    var body: some View { content }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.dormant && rhs.dormant }
}

/// A mask showing everything but the grid's bottom bar, as far as the
/// bar's controls have faded in (`shown`, 0 on the page, 1 on the grid).
struct BarCutout: View {
    var bar: CGRect
    var shown: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
            Rectangle()
                .frame(width: bar.width, height: bar.height + 16)
                .offset(x: bar.minX, y: bar.minY - 8)
                .opacity(min(1, max(0, shown)))
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}
#endif
