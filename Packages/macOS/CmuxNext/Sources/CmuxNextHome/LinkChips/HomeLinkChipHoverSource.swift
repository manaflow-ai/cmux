public import AppKit
public import CmuxNextDesign
public import MessagesLabHome

/// The Home transcript's side of the app's hover cards (`HoverCardCoordinator`) for link chips:
/// it hit-tests chips (``MessagesLabHomeView/linkChip(atScreenPoint:)``), names each by its URL,
/// supplies the one reused card body, and fills it from the app (`HomeLinkPreviewing`): the quick
/// facts when the card opens, the slower ones (lines, thumbnail) when they arrive. Timing,
/// showing, hiding and dismissal belong to the coordinator.
@MainActor
public final class HomeLinkChipHoverSource: HoverCardSource {
    /// The transcript whose chips these are.
    weak var transcript: MessagesLabHomeView?
    /// The app's one coordinator.
    public let coordinator: HoverCardCoordinator
    /// The app's facts about each target.
    public let previewer: any HomeLinkPreviewing
    /// The chips last hit, by target id: their URL, kind and frame on screen.
    private var hits: [HoverTargetID: HomeLinkChipHit] = [:]
    private var body: HomeLinkPreviewCardView?
    private var shownID: HoverTargetID?
    // task-owner: one details fetch for the shown card; cancelled when the card leaves it
    private var detailsTask: Task<Void, Never>?

    /// - Parameters:
    ///   - transcript: the Home transcript whose chips get cards.
    ///   - coordinator: the app's one hover card coordinator.
    ///   - previewer: the app's facts about each chip's target.
    init(transcript: MessagesLabHomeView, coordinator: HoverCardCoordinator, previewer: any HomeLinkPreviewing) {
        self.transcript = transcript
        self.coordinator = coordinator
        self.previewer = previewer
    }

    /// A chip's target id: its URL (two chips to one target share a card).
    static func targetID(_ url: URL) -> HoverTargetID { HoverTargetID("homeChip:\(url.absoluteString)") }

    /// The card body shown now (tests, `debug.hover_cards`).
    var shownBody: HomeLinkPreviewCardView? { shownID == nil ? nil : body }

    // MARK: HoverCardSource

    public var hoverCardWindow: NSWindow? { transcript?.window }

    public func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit? {
        guard let transcript, let window = transcript.window, let hit = transcript.linkChip(atScreenPoint: screenPoint) else { return nil }
        let id = Self.targetID(hit.url)
        if hits.count > 64 { hits = hits.filter { $0.key == shownID } }
        hits[id] = hit
        return HoverCardHit(target: HoverTarget(id: id, window: window.windowNumber, delay: DesignSettings.shared.hoverCardDelay),
                            anchor: hit.rect)
    }

    public func hoverCardAnchor(for id: HoverTargetID) -> CGRect? { hits[id]?.rect }

    public func hoverCardBody(for id: HoverTargetID) -> HoverCardBody? {
        guard let transcript, let hit = hits[id] else { return nil }
        let body = body ?? HomeLinkPreviewCardView()
        self.body = body
        if shownID != id || body.preview == nil {
            body.configure(previewer.preview(for: hit.url, kind: hit.kind))
        }
        return HoverCardBody(view: body, placement: .above, themeAnchor: transcript) { [weak body] in body?.applyColors() }
    }

    public func hoverCardActivated(_ id: HoverTargetID) {
        guard shownID != id, let hit = hits[id] else { return }
        shownID = id
        detailsTask?.cancel()
        let previewer = previewer
        let quick = previewer.preview(for: hit.url, kind: hit.kind)
        body?.configure(quick)
        // main-hop-allow: details is the app's main-actor async preview read (HomeLinkPreviewing: a terminal's lines, a file's head, a thumbnail); this task only starts it and fills the shown card in its resume
        detailsTask = Task { [weak self] in
            let full = await previewer.details(for: hit.url, preview: quick)
            guard let self, !Task.isCancelled, self.shownID == id, full != quick else { return }
            self.body?.configure(full)
            self.coordinator.contentChanged(id)
        }
    }

    public func hoverCardDeactivated(_ id: HoverTargetID) {
        guard shownID == id else { return }
        detailsTask?.cancel()
        detailsTask = nil
        shownID = nil
    }
}
