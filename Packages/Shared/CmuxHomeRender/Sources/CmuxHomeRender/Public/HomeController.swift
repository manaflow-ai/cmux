public import CmuxHomeCore
public import CoreGraphics
public import Foundation
public import QuartzCore

/// The public face of the Home render core. A host (UIKit on iOS, AppKit on
/// the Mac) owns one controller per open conversation, adds `rootLayer` to
/// its view's layer, forwards resizes and `HomeInput`, feeds CmuxHomeCore
/// state through `update`, and sends the `HomeIntent`s it emits to the
/// conversation's owner (`HomeStore.perform`, see `HomeStoreBinding`).
///
/// Time is event-driven: Core Animation runs every animation on the render
/// server; the controller wakes once per cleanup due time through the
/// host's one-shot `HomeDeadline`. No display link, no polling, no sleep:
/// idle is 0% CPU.
@MainActor
public final class HomeController {
    public let conversation: ConversationID
    public let me: ParticipantID
    let scene: HomeScene
    let builder: RowBuilder
    private let deadline: any HomeDeadline
    private let currentDate: @MainActor () -> Date
    private var wakeAt: CFTimeInterval = .infinity

    private(set) var items: [TranscriptItem] = []
    private(set) var summary: ConversationSummary?
    private(set) var typing: Set<ParticipantID> = []
    /// More history exists before the loaded window (`HomeStore.hasOlderMessages`).
    public private(set) var hasOlder = false
    var olderRequested = false
    /// My last send from the field until its item appears (the morph source and
    /// the text to restore if the owner refuses it before it is logged).
    var pendingSend: (intent: HomeIntent, text: String, field: CGRect)?
    var reportedRead: Seq = 0

    /// Called with every typed change for the owner (send, read cursor).
    public var onIntent: (HomeIntent) -> Void = { _ in }
    /// The viewport reached the oldest loaded row while `hasOlder` (`HomeStore.loadOlder`).
    public var onNeedsOlder: () -> Void = {}
    /// The accessibility items changed (rows, scroll or the draft).
    public var onAccessibilityChange: () -> Void = {}
    /// The scroll range or the offset changed by the model (rows added, pin
    /// on send, prepend rebase, resize). Hosts with a native scroll view
    /// resize their document and move their clip view (see `scrollGeometry`).
    public var onScrollGeometryChange: (ScrollGeometry) -> Void = { _ in }
    var lastPublishedGeometry: ScrollGeometry?
    /// The conversation's summary changed (title, participants): hosts
    /// refresh their header.
    public var onSummaryChange: (ConversationSummary?) -> Void = { _ in }
    /// A send the owner refused before logging it, in hosted-field mode:
    /// the host puts `text` back into its own field if that is empty.
    public var onRestoreDraft: (String) -> Void = { _ in }
    /// The rows changed (not just the viewport): hosts post their platform's
    /// layout-changed accessibility notification here.
    public var onRowsChange: () -> Void = {}
    let container = CALayer()
    var hostSize: CGSize = .zero
    var zoom: CGFloat = 1
    var displayScale: CGFloat = Canvas.scale
    /// The hosted field as the host gave it (host points).
    var hostedFieldInHost: CGRect?
    /// The latest summary from `update`.
    public var conversationSummary: ConversationSummary? { summary }
    /// The host shows this conversation to the user (window visible, app
    /// active). Read cursors advance only while it is true.
    public var isVisibleToUser = false {
        didSet { if isVisibleToUser { reportReadIfNeeded() } }
    }

    /// - Parameters:
    ///   - palette: colours from the app theme (`HomePalette.themed`); there is no default.
    ///   - deadline: the host's one-shot timer for cleanup after animations.
    public init(conversation: ConversationID, me: ParticipantID, palette: HomePalette, deadline: any HomeDeadline,
                calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.conversation = conversation
        self.me = me
        self.deadline = deadline
        currentDate = now
        scene = HomeScene(palette: palette)
        builder = RowBuilder(format: RowFormat(calendar: calendar, locale: locale))
        container.actions = RowLayer.noActions
        container.masksToBounds = true
        container.addSublayer(scene.root)
        scene.requestWake = { [weak self] due in self?.scheduleWake(at: due) }
        scene.offsetMovedByModel = { [weak self] in self?.publishScrollGeometryIfChanged() }
        scene.compose.restartCaret(begin: scene.now, sent: false, motion: scene.motion)
    }

    /// The host adds this layer and sets its frame to the view's bounds.
    public var rootLayer: CALayer { container }
    /// The viewport in host points.
    public var size: CGSize { hostSize }

    public func resize(to size: CGSize) {
        hostSize = size
        applyZoom()
    }

    /// Text size relative to the 13 pt reference (1 = Mac default; iOS
    /// passes Dynamic Type's body size / 13, the Mac the user's text size).
    /// The whole transcript scales with it (fonts, paddings, radii, gaps);
    /// rows are re-measured and redrawn sharp at the new size.
    public var textScale: CGFloat {
        get { zoom }
        set {
            let value = max(0.5, min(5, newValue))
            guard value != zoom else { return }
            zoom = value
            scene.setContentsScale(displayScale * zoom)
            applyZoom()
        }
    }

    /// Device pixels per point of the host (2 on Mac, 3 on most iPhones).
    /// Row bitmaps are drawn at this times `textScale`.
    public var contentsScale: CGFloat {
        get { displayScale }
        set {
            guard newValue > 0, newValue != displayScale else { return }
            displayScale = newValue
            scene.setContentsScale(displayScale * zoom)
        }
    }

    private func applyZoom() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scene.root.anchorPoint = .zero
        scene.root.position = .zero
        scene.root.transform = CATransform3DMakeScale(zoom, zoom, 1)
        CATransaction.commit()
        if let field = hostedFieldInHost { scene.hostedField = toDesign(field) }
        let design = CGSize(width: hostSize.width / zoom, height: hostSize.height / zoom)
        scene.resize(to: design) { self.rows(metrics: $0) }
        publishScrollGeometryIfChanged()
        afterViewportChange()
    }

    /// Host points -> the core's design points (and back).
    func toDesign(_ r: CGRect) -> CGRect { CGRect(x: r.minX / zoom, y: r.minY / zoom, width: r.width / zoom, height: r.height / zoom) }
    func toHost(_ r: CGRect) -> CGRect { CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom) }
    func toDesign(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / zoom, y: p.y / zoom) }

    /// Space the host covers at the top (toolbar, safe area); rows scroll under it.
    public var topInset: CGFloat {
        get { scene.topInset * zoom }
        set {
            let design = newValue / zoom
            guard design != scene.topInset else { return }
            let anchor = scene.visibleAnchor()
            scene.topInset = design
            scene.restore(anchor)
        }
    }

    public var reduceMotion: Bool {
        get { scene.motion.reduceMotion }
        set { setMotion(MotionPolicy(reduceMotion: newValue, speed: scene.motion.speed)) }
    }

    public var animationSpeed: HomeAnimationSpeed {
        get { scene.motion.speed }
        set { setMotion(MotionPolicy(reduceMotion: scene.motion.reduceMotion, speed: newValue)) }
    }

    private func setMotion(_ policy: MotionPolicy) {
        guard policy != scene.motion else { return }
        scene.motion = policy
        scene.markAllDirty()
        scene.layoutRows()
        scene.compose.restartCaret(begin: scene.now, sent: false, motion: policy)
    }

    /// Colours (for example `HomePalette.themed(theme, active: false)` while the window is not key).
    public var palette: HomePalette {
        get { scene.palette }
        set { scene.setPalette(newValue) }
    }

    /// The transcript follows its newest row (the user has not scrolled up).
    public var isPinnedToNewest: Bool { scene.pinned }

    /// Nothing animates, no cleanup is pending and no row bitmap is being drawn.
    public var isIdle: Bool { wakeAt == .infinity && !scene.isAnimating && !scene.bitmaps.isRendering }

    // MARK: State from CmuxHomeCore

    /// New transcript state: `items` from `HomeStore.transcript(for:)`,
    /// `summary` from `HomeStore.summary(_:)` (participants, read cursors),
    /// `typing` from `HomeStore.typing[conversation]`.
    public func update(items newItems: [TranscriptItem], summary newSummary: ConversationSummary?,
                       typing newTyping: Set<ParticipantID>, hasOlder newHasOlder: Bool) {
        let unchanged = newItems == items && newTyping == typing && newHasOlder == hasOlder
            && newSummary?.readCursors == summary?.readCursors && newSummary?.participants == summary?.participants
        guard !unchanged else { return }
        let oldOthersTyping = !typing.subtracting([me]).isEmpty
        let newOthersTyping = !newTyping.subtracting([me]).isEmpty
        var change = TranscriptChange.classify(old: items, new: newItems, me: me, typing: (oldOthersTyping, newOthersTyping),
                                               read: (Self.readByOthers(summary, me: me), Self.readByOthers(newSummary, me: me)))
        items = newItems
        let summaryChanged = newSummary != summary
        summary = newSummary
        if summaryChanged { onSummaryChange(newSummary) }
        typing = newTyping
        if newHasOlder != hasOlder || change == .prepend { olderRequested = false }
        hasOlder = newHasOlder
        var sendField: CGRect?
        if let pending = pendingSend, newItems.contains(where: { $0.key == pending.intent.key }) {
            if change == .send(pending.intent.key) { sendField = pending.field }
            pendingSend = nil
        }
        if case .send = change, sendField == nil { change = .other }
        if change == .initial { scene.pinned = true }
        guard scene.size.width > 0 else { return }
        scene.commit(rows(metrics: scene.metrics), change: change, sendField: sendField)
        onRowsChange()
        publishScrollGeometryIfChanged()
        askForOlderIfNeeded()
        reportReadIfNeeded()
        onAccessibilityChange()
    }

    func rows(metrics: Metrics) -> [RowSpec] {
        let names = Dictionary((summary?.participants ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        return builder.rows(items, RowContext(me: me, now: currentDate(), metrics: metrics,
                                              readByOthers: Self.readByOthers(summary, me: me),
                                              othersTyping: !typing.subtracting([me]).isEmpty,
                                              names: names, showsNames: summary?.kind(me: me) == .group))
    }

    static func readByOthers(_ summary: ConversationSummary?, me: ParticipantID) -> Seq? {
        summary?.readCursors.filter { $0.key != me }.values.max()
    }

    /// Advances my read cursor to the newest committed message while the
    /// newest row is on screen and the user can see it.
    func reportReadIfNeeded() {
        guard isVisibleToUser, scene.pinned, let newest = items.last(where: { $0.seq != nil })?.seq else { return }
        let cursor = max(reportedRead, summary?.readCursors[me] ?? 0)
        guard newest > cursor else { return }
        reportedRead = newest
        onIntent(HomeIntent(op: .setReadCursor(conversation: conversation, seq: newest)))
    }

    func afterViewportChange() {
        askForOlderIfNeeded()
        reportReadIfNeeded()
        onAccessibilityChange()
    }

    /// Once per page: the oldest loaded row is within a screen of the viewport
    /// (also when the loaded rows do not fill the viewport and cannot scroll).
    private func askForOlderIfNeeded() {
        guard scene.nearOldest, hasOlder, !olderRequested else { return }
        olderRequested = true
        onNeedsOlder()
    }

    // MARK: Event-driven wake-ups

    private func scheduleWake(at due: CFTimeInterval) {
        guard due < wakeAt else { return }
        wakeAt = due
        deadline.schedule(after: .seconds(max(0, due - scene.now))) { [weak self] in self?.wakeFired(due) }
    }

    private func wakeFired(_ due: CFTimeInterval) {
        wakeAt = .infinity
        scene.settle(at: max(scene.now, due))
    }
}
