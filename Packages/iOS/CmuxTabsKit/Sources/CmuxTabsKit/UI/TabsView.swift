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
    /// The page <-> grid transition (one interruptible progress value).
    @State private var zoomDriver = TabZoomDriver()
    /// Tab the zoom shows: the active tab, a tapped card, or a created tab.
    @State private var zoomTabId: String?
    /// Grid content origin in the screen's coordinate space, reported by the grid.
    @State private var gridContentOrigin: CGPoint?
    /// (+) pressed and the tab not created yet: the grid shows a placeholder card.
    @State private var pendingNewTab: TabsKitNewTabOption?
    /// The pinch that drives the zoom (page -> grid, card -> page, or grabbing a running zoom).
    @State private var pinchSession = ZoomPinchSession()
    @State private var zoomPinchActive = false
    @State private var overviewScroll: CGFloat = 0
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

    private var overviewLayout: OverviewLayout {
        OverviewLayout(size: size, safeTop: safeTop, safeBottom: safeBottom, count: tabs.count + (pendingNewTab == nil ? 0 : 1))
    }

    private var toolbarLayout: ToolbarLayout {
        ToolbarLayout.make(metrics: theme.metrics, size: size, safeBottom: safeBottom, keyboard: keyboard, bar: chrome.bar,
                           editing: chrome.editing, splitBack: activeTab?.navigation.canGoForward == true, labelWidth: 69,
                           noBack: activeTab?.features.contains(.history) != true)
    }

    var body: some View {
        let layout = toolbarLayout
        ZStack(alignment: .topLeading) {
            // Kept mounted (hidden) so opening it does not pay for building
            // the grid on the first animation frame.
            TabOverview(source: source, layout: overviewLayout, shown: overviewShown, chrome: zoomDriver.chrome,
                        hiddenTabId: zoomState.phase == .overview ? nil : zoomTabId,
                        gridInteractive: zoomState.gridInteractive,
                        controlsInteractive: overviewVisible && zoomState.headingToOverview,
                        scrollOffset: $overviewScroll, position: $overviewPosition,
                        onSelect: { closeOverview(selecting: $0) },
                        onClose: { id in withAnimation(theme.motion.resolve(theme.motion.reflow)) { source.close(id) } },
                        onNewTab: newTabFromOverview,
                        onDone: { closeOverview(selecting: activeID) },
                        onCloseAll: closeAll,
                        pending: pendingNewTab,
                        onContentOrigin: { origin in if gridContentOrigin != origin { gridContentOrigin = origin } })
                .opacity(overviewVisible ? 1 : 0)
                .allowsHitTesting(overviewVisible)
                .accessibilityHidden(!zoomState.gridInteractive)

            if chrome.swiping {
                swipeNeighbor
            }

            pageLayer

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
                        onSwipeChanged: swipeChanged, onSwipeEnded: swipeEnded)
                .opacity(1 - overviewShown)
                // Usable on the page, and while a zoom heads back to the page
                // (the tabs button then reverses it).
                .allowsHitTesting(!chrome.menuOpen && (zoomState.pageInteractive || (zoomState.phase == .animating && !zoomState.headingToOverview)))

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
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named(TabsScreenSpace.name))
        .gesture(ZoomPinchGesture { handlePinch($0) })
        .onChange(of: size.width, initial: true) { _, w in zoomDriver.span = Double(w - overviewLayout.cardWidth) }
        .onAppear {
            zoomDriver.onSettle = { phase in
                if phase == .page {
                    zoomTabId = nil
                    chrome.expand(tap: true, theme)
                }
            }
        }
        .onChange(of: isShowingOverview?.wrappedValue, initial: true) { _, wanted in
            guard let wanted, wanted != zoomState.headingToOverview else { return }
            if wanted { openOverview() } else { closeOverview(selecting: activeID) }
        }
        .onChange(of: zoomState.headingToOverview) { _, heading in
            if let binding = isShowingOverview, binding.wrappedValue != heading { binding.wrappedValue = heading }
        }
        .onChange(of: tabs.isEmpty, initial: true) { _, empty in
            // Closing the last tab opens a fresh one, as Safari does.
            if empty, !overviewVisible, let option = source.newTabOptions.first {
                Task { _ = await source.createTab(option) }
            }
        }
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

    /// The active tab's live page. It stays at one place in the view tree;
    /// a zoom only changes its scale, clip and offset, so the client's view
    /// (a web view, a terminal) is never rebuilt by a transition. It is laid
    /// out at full size and scaled into the zooming rect.
    @ViewBuilder private var pageLayer: some View {
        let settled = zoomState.phase == .page
        let g = settled ? (rect: fullRect, radius: chrome.swiping ? theme.metrics.screenRadius : 0) : zoomGeometry()
        let scale = size.width > 0 ? max(0.01, g.rect.width / size.width) : 1
        ZStack(alignment: .topLeading) {
            theme.colors.pageBackground
            if let tab = activeTab {
                source.content(for: tab, context: contentContext)
                    .id(tab.id)
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: max(1, g.rect.width), height: max(1, g.rect.height), alignment: .topLeading)
        .clipShape(.rect(cornerRadius: g.radius, style: .continuous))
        // The card's close button rides its corner at full size and fades in
        // with the zoom's progress (CardChrome).
        .overlay(alignment: .topTrailing) {
            if zoomTabId != TabsScreenSpace.newTabMarker {
                CardCloseGlyph()
                    .padding(4)
                    .opacity(CardChrome.zoomCloseOpacity(progress: zoomState.progress,
                                                         headingToOverview: zoomState.phase == .interactive || zoomState.headingToOverview))
                    .allowsHitTesting(false)
            }
        }
        .offset(x: g.rect.minX + (chrome.swiping ? chrome.swipeOffset : 0), y: g.rect.minY)
        .opacity(zoomState.phase == .overview ? 0 : 1)
        .allowsHitTesting(settled && !chrome.swiping && !chrome.editing)
        .accessibilityHidden(!settled)
        .tabsKitStatusBarStyle(overviewVisible ? nil : activeTab?.statusBarStyle)
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
                        ScaledContent(pageSize: size) { source.card(for: tab) }
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
        let index: Int
        if zoomTabId == TabsScreenSpace.newTabMarker {
            index = tabs.count
        } else {
            index = zoomTabId.flatMap { id in tabs.firstIndex { $0.id == id } } ?? (activeIndex ?? 0)
        }
        let grid = OverviewLayout(size: size, safeTop: safeTop, safeBottom: safeBottom, count: max(tabs.count, index + 1))
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
        let grid = OverviewLayout(size: size, safeTop: safeTop, safeBottom: safeBottom, count: count)
        let offset = grid.offset(revealing: index, from: overviewScroll)
        if abs(offset - overviewScroll) > 0.5 {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { overviewPosition = ScrollPosition(y: offset) }
            // Until the scroll view reports it, the fallback endpoint uses it too.
            overviewScroll = offset
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
    /// its slot); the zoom grows from that slot once the client created the
    /// tab. A refused create leaves the grid as it was.
    private func newTabFromOverview(_ option: TabsKitNewTabOption) {
        guard zoomState.phase == .overview, pendingNewTab == nil else { return }
        pendingNewTab = option
        Task {
            let id = await source.createTab(option)
            withAnimation(theme.motion.resolve(theme.motion.reflow)) { pendingNewTab = nil }
            guard let id else { return }
            openCreated(id)
        }
    }

    /// Zooms from a just-created tab's card into it (grid only).
    private func openCreated(_ id: String) {
        guard zoomState.phase == .overview, tabs.contains(where: { $0.id == id }) else { return }
        if activeID != id { source.activate(id) }
        zoomTabId = id
        zoomDriver.go(toOverview: false)
    }

    private func closeAll() {
        let ids = tabs.map(\.id)
        withAnimation(theme.motion.resolve(theme.motion.reflow)) { for id in ids { source.close(id) } }
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
#endif
