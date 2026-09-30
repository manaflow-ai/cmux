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

/// Shows a Liquid Glass preview card under a hovered tab or chip, with Chrome timing:
/// a width-dependent delay before the first card, then instant updates while
/// the pointer moves across tabs.
final class TabHoverCardController {
    weak var previewProvider: (any TabPreviewProvider)?
    /// Samples CPU and memory of the hovered tab while its card is pending
    /// or shown (first sample at hover start), never otherwise.
    let resources = ResourceCardSampler(source: nil)
    /// Ends a card an action opened (not the pointer).
    private let pin = PinnedCardDismissal()
    var policy = HoverCardPolicy()
    var metrics = TabStripMetrics.standard

    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: () -> ContinuousClock.Instant
    private var panel: TabHoverCardPanel?
    private var pendingShow: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private(set) var shownID: TabID?
    private var pendingID: TabID?
    private var lastHidden: ContinuousClock.Instant?
    private var thumbnails: [TabID: CGImage] = [:]

    init(
        // wakeup-allow: one-shot hover-delay debounce (injected for tests), cancelled on hide
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) },
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.sleep = sleep
        self.now = now
    }

    var isVisible: Bool { shownID != nil }

    /// Pointer is over `tab`, whose frame on screen is `anchor`.
    func hover(_ content: TabHoverCardContent, anchor: CGRect, tabWidth: CGFloat, parent: NSWindow?) {
        if shownID == content.id {
            return
        }
        if pendingID == content.id { return }
        pendingShow?.cancel()
        pin.disarm()
        startResources(for: content)
        let delay = policy.delay(
            tabWidth: tabWidth,
            cardIsVisible: isVisible,
            sinceLastHidden: lastHidden.map { now() - $0 },
            metrics: metrics
        )
        if delay == .zero {
            show(content, anchor: anchor, parent: parent)
            return
        }
        pendingID = content.id
        pendingShow = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, !Task.isCancelled, self.pendingID == content.id else { return }
            self.show(content, anchor: anchor, parent: parent)
        }
    }

    /// Shows the card now, without the hover delay, until the next key
    /// press, click or scroll (the "Show Resource Usage" actions).
    func showPinned(_ content: TabHoverCardContent, anchor: CGRect, parent: NSWindow?) {
        pendingShow?.cancel()
        pendingShow = nil
        pendingID = nil
        startResources(for: content)
        show(content, anchor: anchor, parent: parent)
        guard shownID == content.id else {
            resources.close()
            return
        }
        pin.arm { [weak self] in self?.hide(allowsQuickReshow: false) }
    }

    /// Design tokens changed: rebuild the card at the new sizes next time.
    func tokensChanged() {
        hide(allowsQuickReshow: false)
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }

    /// Refreshes the visible card when its content changes.
    func refresh(_ content: TabHoverCardContent) {
        guard shownID == content.id else { return }
        panel?.configure(content)
    }

    /// Hides the card. `allowsQuickReshow` starts Chrome's grace window in
    /// which the next hover shows a card without delay; clicks and scrolls
    /// pass false so a card does not pop up right after them.
    func hide(allowsQuickReshow: Bool = true) {
        pendingShow?.cancel()
        pendingShow = nil
        pendingID = nil
        pin.disarm()
        resources.close()
        thumbnailTask?.cancel()
        guard let panel, shownID != nil else { return }
        shownID = nil
        lastHidden = allowsQuickReshow ? now() : nil
        thumbnails.removeAll()
        panel.dismiss()
    }

    private func show(_ content: TabHoverCardContent, anchor: CGRect, parent: NSWindow?) {
        guard let parent, parent.isVisible else { return }
        pendingID = nil
        let wasVisible = isVisible
        let panel = panel ?? TabHoverCardPanel()
        self.panel = panel
        shownID = content.id
        panel.configure(content)
        if case .tab = content { panel.setResources(resources.report) }
        panel.setThumbnail(thumbnails[content.id])
        panel.present(below: anchor, parent: parent, sliding: wasVisible)
        if case .tab(let item) = content { loadThumbnail(for: item.id) }
    }

    /// Starts sampling the tab under the pointer (the first sample is the
    /// CPU baseline, taken at hover start so the card shows CPU about one
    /// interval later). Group chips have no resource line.
    private func startResources(for content: TabHoverCardContent) {
        guard case .tab(let item) = content else {
            resources.close()
            return
        }
        resources.open(.tab(item.id.rawValue)) { [weak self] report in
            guard let self, self.shownID == item.id else { return }
            self.panel?.setResources(report)
        }
    }

    private func loadThumbnail(for id: TabID) {
        thumbnailTask?.cancel()
        guard let provider = previewProvider else { return }
        let scale = panel?.backingScaleFactor ?? 2
        let size = CGSize(width: TabHoverCardPanel.thumbnailSize.width * scale, height: TabHoverCardPanel.thumbnailSize.height * scale)
        thumbnailTask = Task { [weak self] in
            let image = await provider.previewImage(for: id, maxPixelSize: size)
            guard let self, !Task.isCancelled, self.shownID == id else { return }
            if let image { self.thumbnails[id] = image }
            self.panel?.setThumbnail(image)
        }
    }
}
