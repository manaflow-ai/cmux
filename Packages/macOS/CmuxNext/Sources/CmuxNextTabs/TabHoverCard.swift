import AppKit
import CmuxNextDesign
import CmuxNextResources
import QuartzCore

/// What a hover card shows.
enum TabHoverCardContent: Equatable {
    case tab(TabItem)
    /// A group chip: the group and its member titles in order.
    case group(TabGroupItem, memberTitles: [String])

    var id: TabID {
        switch self {
        case .tab(let item): item.id
        case .group(let group, _): .groupChip(group.id)
        }
    }
}

/// A tab strip's side of the app's hover cards (`HoverCardCoordinator`):
/// it names the strip's targets (tabs and group chips) by id, hit-tests
/// them, supplies the one reused card body, samples the active tab's CPU
/// and memory, and keeps recent thumbnails and samples so a retarget never
/// blanks the card (R131). Timing, showing and hiding belong to the
/// coordinator.
@MainActor
final class TabHoverCardController: HoverCardSource {
    weak var previewProvider: (any TabPreviewProvider)?
    /// The strip whose targets these are.
    weak var strip: TabStripView?
    /// Samples CPU and memory of the hovered tab while its card shows (first
    /// sample when it shows: a sweep across tabs samples none), never otherwise.
    let resources = ResourceCardSampler(source: nil)
    /// Pointer rest before a tab's card opens: `HoverCardTiming.showDelay`,
    /// or `sidebar.hoverCards.delay`; read on
    /// each hover so a Settings change applies at once. Every tab waits the
    /// same, as a sidebar row does (no width scaling, cx-23e1f).
    var delay: Duration { DesignSettings.shared.hoverCardDelay }
    /// Like a browser's tab preview (Leo 2026-10-14): leaving the tab hides its card at once,
    /// and another tab reached within the reshow window shows its card at once.
    var leave: HoverCardLeave { .hides(reshow: HoverCardTiming.reshowWindow) }
    /// The app's one coordinator; the App injects it, a demo strip uses its own.
    var coordinator: HoverCardCoordinator {
        didSet {
            guard coordinator !== oldValue else { return }
            oldValue.unregister(self)
            if strip?.window != nil { coordinator.register(self) }
        }
    }

    private var body: TabHoverCardView?
    /// Group chips' summary card body, reused chip to chip.
    private var groupBody: GroupHoverCardView?
    private var thumbnailTask: Task<Void, Never>?
    /// Recently hovered tabs' thumbnails.
    var thumbnails = TabThumbnailCache()
    /// Each recently hovered tab's last measured sample and when it was taken, shown
    /// until the first fresh one arrives (no placeholder flash on a retarget), and
    /// for a hibernated page what it was using.
    private var lastReports: [TabID: (report: ResourceReport, at: Date)] = [:]
    /// A hibernated page's card names what it was using only from a sample this recent.
    static let hibernatedSampleLifetime: TimeInterval = 10 * 60
    /// The time now (tests move it).
    var now: () -> Date = Date.init
    /// Tabs whose last fetch had no thumbnail: their cards open without one.
    private var noThumbnail: Set<TabID> = []
    private var bodyID: HoverTargetID?
    /// The next card opens from hidden, not by a retarget: a tab whose thumbnail is not
    /// known yet gets the empty frame its thumbnail fades into.
    private var opensFresh = true
    private var memoryPressure: (any DispatchSourceMemoryPressure)?

    init(coordinator: HoverCardCoordinator = HoverCardCoordinator()) {
        self.coordinator = coordinator
        #if DEBUG
        HoverCardGallery.register("tabs") { TabHoverCardGallery.cards() }
        #endif
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.thumbnails.removeAll()
                self?.lastReports.removeAll()
            }
        }
        source.activate()
        memoryPressure = source
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            memoryPressure?.cancel()
        }
    }

    /// The image the card body shows now (`debug.hover_sweep`).
    var shownThumbnail: CGImage? { body?.thumbnailImage }

    static func targetID(_ id: TabID) -> HoverTargetID {
        HoverTargetID("tab:\(id.rawValue)")
    }

    /// The strip's tab id for a target id of this strip.
    private func tabID(_ id: HoverTargetID) -> TabID? {
        let raw = id.rawValue
        return raw.hasPrefix("tab:") ? TabID(String(raw.dropFirst(4))) : nil
    }

    /// This strip's tab or chip whose card shows now.
    var shownID: TabID? {
        guard let id = coordinator.machine.shownTarget?.id, let tab = tabID(id), content(for: tab) != nil else { return nil }
        return tab
    }
    var isVisible: Bool { shownID != nil }

    // MARK: HoverCardSource

    var hoverCardWindow: NSWindow? { strip?.window }

    func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
        guard let strip, let window = strip.window,
              let target = self.target(at: strip.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        else { return nil }
        return HoverCardHit(
            target: HoverTarget(id: Self.targetID(target.id), window: window.windowNumber,
                                delay: target.id.isGroupChip ? DesignSettings.shared.groupHoverCard.delay : delay, leave: leave),
            anchor: target.anchor
        )
    }

    /// A point in the strip on no tab (a gap, a New Tab page's tab): a shown card waits
    /// there for the next tab.
    func hoverCardBridges(at screenPoint: CGPoint) -> Bool {
        guard let strip, let window = strip.window, !strip.isHiddenOrHasHiddenAncestor else { return false }
        return strip.visibleRect.contains(strip.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    func hoverCardAnchor(for id: HoverTargetID) -> CGRect? {
        guard let tab = tabID(id) else { return nil }
        return anchor(forTab: tab)
    }

    func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
        guard let strip, let tab = tabID(id), let content = self.content(for: tab) else { return nil }
        if let group = tab.chipGroupID, let item = strip.groups.byID[group] {
            let body = groupBody ?? GroupHoverCardView()
            groupBody = body
            body.configure(strip.groupHoverSummary(item, options: DesignSettings.shared.groupHoverCard, now: now()))
            bodyID = id
            return HoverCardBody(view: body, placement: Self.placement(for: DesignSettings.shared.tabBarPosition), themeAnchor: strip) { [weak body] in
                body?.applyColors()
            }
        }
        let body = body ?? TabHoverCardView()
        self.body = body
        body.configure(content)
        // Compact previews (Debug Settings `tabs.hoverPreviews`) show the facts without a thumbnail.
        let full = TabTunables.hoverPreviews.value == .full
        if case .tab = content {
            body.setResources(resources.report ?? lastReport(for: tab))
            // On a retarget, a tab whose thumbnail is not known yet keeps what the card
            // shows (the last tab's picture, or no frame) until its own lands: never an
            // empty frame that collapses again (R131). A card opening fresh shows no frame
            // until the picture lands (`loadThumbnail` grows it): an empty gray well under
            // the facts read as broken (Leo 2026-10-20).
            if !full || noThumbnail.contains(tab) {
                body.setThumbnailVisible(false)
            } else if thumbnails.image(for: tab) != nil {
                body.setThumbnailVisible(true)
            } else if bodyID != id && opensFresh {
                body.setThumbnailVisible(false)
            }
        }
        let newCard = bodyID != id
        if newCard { opensFresh = false }
        // A retarget keeps the shown thumbnail until this tab's lands; a tab
        // seen before shows its own at once.
        if newCard, full, let cached = thumbnails.image(for: tab) { body.setThumbnail(cached) }
        bodyID = id
        // Once per card, not on every content refresh (resource samples).
        if newCard, full, case .tab = content { loadThumbnail(for: tab) }
        if newCard, case .tab = content { startSampling(tab, card: id) }
        // The card hangs from its tab with no gap: it takes the tab's corners.
        return HoverCardBody(view: body, placement: Self.placement(for: DesignSettings.shared.tabBarPosition), themeAnchor: strip,
                             cornerRadius: strip.metrics.cornerRadius) { [weak body] in body?.applyColors() }
    }

    func hoverCardActivated(_ id: HoverTargetID) {
        guard let tab = tabID(id), !tab.isGroupChip else { return }
        forgetClosedTabs()
    }

    /// The shown card's tab: sampled once a second while it shows. A hibernated page has
    /// no process to sample: its card keeps the last sample from before it hibernated.
    private func startSampling(_ tab: TabID, card id: HoverTargetID) {
        guard !tab.isGroupChip, strip?.model.tab(tab)?.isDormant != true else { return }
        resources.open(.tab(tab.rawValue)) { [weak self] report in
            guard let self else { return }
            self.rememberReport(report, for: tab)
            guard self.bodyID == id else { return }
            self.body?.setResources(report)
            self.coordinator.contentChanged(id)
        }
    }

    /// The card left `id`: sampling and a fetch in flight stop. On a
    /// retarget the body keeps what it shows until the next tab's data
    /// lands (no blank frame).
    func hoverCardDeactivated(_ id: HoverTargetID) {
        resources.close()
        thumbnailTask?.cancel()
        bodyID = nil
        // A card that hides starts its next show blank, never with this tab's image.
        // Its frame stays as it is while it fades out.
        if !cardIsShowing() {
            body?.setThumbnail(nil)
            body?.resetResourceHistory()
            opensFresh = true
        }
    }

    /// Whether a card is on screen (a deactivation then is a retarget, not
    /// a hide). Tests replace it.
    lazy var cardIsShowing: () -> Bool = { [weak self] in self?.coordinator.machine.shownTarget != nil }

    /// Closed tabs' thumbnails and samples go (at the next hover).
    private func forgetClosedTabs() {
        guard let strip else { return }
        let open = Set(strip.model.tabs.map(\.id))
        thumbnails.keep(only: open)
        lastReports = lastReports.filter { open.contains($0.key) }
        noThumbnail.formIntersection(open)
    }

    /// Keeps a sample that measured the tab: a zero or unavailable one would make a
    /// hibernated page claim it was using nothing.
    private func rememberReport(_ report: ResourceReport, for tab: TabID) {
        guard let row = report.tabs.first(where: { $0.id == tab.rawValue }), TabHoverCardLines.measured(row) else { return }
        if lastReports[tab] == nil, lastReports.count >= thumbnails.maxCount { lastReports.removeAll() }
        lastReports[tab] = (report, now())
    }

    /// `tab`'s last measured sample; for a hibernated page only a recent one.
    private func lastReport(for tab: TabID) -> ResourceReport? {
        guard let last = lastReports[tab] else { return nil }
        if strip?.model.tab(tab)?.isDormant == true, now().timeIntervalSince(last.at) > Self.hibernatedSampleLifetime { return nil }
        return last.report
    }

    // MARK: Strip calls

    /// Design tokens changed: the next card rebuilds at the new sizes.
    func tokensChanged() {
        coordinator.dismiss(.action)
        body = nil
        groupBody = nil
        bodyID = nil
    }

    /// `id`'s title, badges or members changed.
    func refresh(_ id: TabID) {
        coordinator.contentChanged(Self.targetID(id))
    }

    private func loadThumbnail(for id: TabID) {
        guard thumbnails.image(for: id) == nil, let provider = previewProvider else { return }
        thumbnailTask?.cancel()
        let scale = strip?.window?.backingScaleFactor ?? 2
        let size = CGSize(width: TabHoverCardView.thumbnailSize.width * scale, height: TabHoverCardView.thumbnailSize.height * scale)
        let target = Self.targetID(id)
        thumbnailTask = Task { [weak self] in
            let image = await provider.previewImage(for: id, maxPixelSize: size)
            guard let self, !Task.isCancelled, self.bodyID == target else { return }
            // No thumbnail (a page never captured): none, not the previous
            // tab's picture kept through the retarget or an empty frame.
            guard let image else {
                self.noThumbnail.insert(id)
                self.body?.setThumbnail(nil)
                self.body?.setThumbnailVisible(false)
                self.coordinator.contentChanged(target)
                return
            }
            self.thumbnails.insert(image, for: id)
            self.noThumbnail.remove(id)
            // A card that showed no frame (the last tab had none) grows one for it.
            let grows = self.body?.showsThumbnail == false
            // It fades into the new frame, not swapped in over a hidden tab's picture.
            if grows { self.body?.setThumbnail(nil) }
            self.body?.setThumbnail(image)
            if grows { self.coordinator.contentChanged(target) }
        }
    }
}

extension TabHoverCardController {
    /// Where a tab's hover card opens: below a strip at the top of its
    /// pane, above one at the bottom (`tabs.barPosition`, R109).
    static func placement(for position: TabBarPosition) -> HoverCardPlacement {
        position == .bottom ? .above : .below
    }
}
