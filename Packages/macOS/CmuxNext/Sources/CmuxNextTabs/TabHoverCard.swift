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
    /// Samples CPU and memory of the hovered tab while its card is pending
    /// or shown (first sample at hover start), never otherwise.
    let resources = ResourceCardSampler(source: nil)
    /// Timing; read fresh on each hover so Debug Settings changes apply at
    /// once, unless a caller pinned one.
    var policy: HoverCardPolicy {
        get { pinnedPolicy ?? HoverCardPolicy() }
        set { pinnedPolicy = newValue }
    }
    private var pinnedPolicy: HoverCardPolicy?
    var metrics = TabStripMetrics.standard
    /// The app's one coordinator; the App injects it, a demo strip uses its own.
    var coordinator: HoverCardCoordinator {
        didSet {
            guard coordinator !== oldValue else { return }
            oldValue.unregister(self)
            if strip?.window != nil { coordinator.register(self) }
        }
    }

    private var body: TabHoverCardView?
    private var thumbnailTask: Task<Void, Never>?
    /// Recently hovered tabs' thumbnails.
    var thumbnails = TabThumbnailCache()
    /// Each recently hovered tab's last CPU and memory sample, shown until
    /// the first fresh one arrives (no placeholder flash on a retarget).
    private var lastReports: [TabID: ResourceReport] = [:]
    private var bodyID: HoverTargetID?
    private var memoryPressure: (any DispatchSourceMemoryPressure)?

    init(coordinator: HoverCardCoordinator = HoverCardCoordinator()) {
        self.coordinator = coordinator
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

    isolated deinit { memoryPressure?.cancel() }

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
        guard let id = coordinator.machine.shownTarget?.id, let tab = tabID(id), strip?.hoverContent(for: tab) != nil else { return nil }
        return tab
    }
    var isVisible: Bool { shownID != nil }

    // MARK: HoverCardSource

    var hoverCardWindow: NSWindow? { strip?.window }

    func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
        guard let strip, let window = strip.window,
              let target = strip.hoverCardTarget(at: strip.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
        else { return nil }
        return HoverCardHit(
            target: HoverTarget(id: Self.targetID(target.id), window: window.windowNumber,
                                delay: policy.showDelay(tabWidth: target.width, metrics: metrics)),
            anchor: target.anchor
        )
    }

    func hoverCardAnchor(for id: HoverTargetID) -> CGRect? {
        guard let tab = tabID(id) else { return nil }
        return strip?.hoverCardAnchor(for: tab)
    }

    func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
        guard let strip, let tab = tabID(id), let content = strip.hoverContent(for: tab) else { return nil }
        let body = body ?? TabHoverCardView()
        self.body = body
        body.configure(content)
        if case .tab = content { body.setResources(resources.report ?? lastReports[tab]) }
        let newCard = bodyID != id
        // A retarget keeps the shown thumbnail until this tab's lands; a tab
        // seen before shows its own at once.
        if newCard, let cached = thumbnails.image(for: tab) { body.setThumbnail(cached) }
        bodyID = id
        // Once per card, not on every content refresh (resource samples).
        if newCard, case .tab = content { loadThumbnail(for: tab) }
        // A strip at the bottom of its pane opens cards upward (R109).
        let placement: HoverCardPlacement = DesignSettings.shared.tabBarPosition == .bottom ? .above : .below
        return HoverCardBody(view: body, placement: placement, themeAnchor: strip) { [weak body] in body?.applyColors() }
    }

    func hoverCardActivated(_ id: HoverTargetID) {
        guard let tab = tabID(id), !tab.isGroupChip else { return }
        forgetClosedTabs()
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
        if !cardIsShowing() { body?.setThumbnail(nil) }
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
    }

    private func rememberReport(_ report: ResourceReport, for tab: TabID) {
        if lastReports[tab] == nil, lastReports.count >= thumbnails.maxCount { lastReports.removeAll() }
        lastReports[tab] = report
    }

    // MARK: Strip calls

    /// Design tokens changed: the next card rebuilds at the new sizes.
    func tokensChanged() {
        coordinator.dismiss(.action)
        body = nil
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
            guard let image else { return }
            self.thumbnails.insert(image, for: id)
            self.body?.setThumbnail(image)
        }
    }
}
