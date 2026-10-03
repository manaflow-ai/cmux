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
        scene.requestWake = { [weak self] due in self?.scheduleWake(at: due) }
        scene.offsetMovedByModel = { [weak self] in self?.publishScrollGeometryIfChanged() }
        scene.compose.restartCaret(begin: scene.now, sent: false, motion: scene.motion)
    }

    public var rootLayer: CALayer { scene.root }
    public var size: CGSize { scene.size }

    public func resize(to size: CGSize) {
        scene.resize(to: size) { self.rows(metrics: $0) }
        publishScrollGeometryIfChanged()
        afterViewportChange()
    }

    /// Space the host covers at the top (toolbar, safe area); rows scroll under it.
    public var topInset: CGFloat {
        get { scene.topInset }
        set {
            guard newValue != scene.topInset else { return }
            let anchor = scene.visibleAnchor()
            scene.topInset = newValue
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
        summary = newSummary
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
        publishScrollGeometryIfChanged()
        askForOlderIfNeeded()
        reportReadIfNeeded()
        onAccessibilityChange()
    }

    func rows(metrics: Metrics) -> [RowSpec] {
        builder.rows(items, RowContext(me: me, now: currentDate(), metrics: metrics,
                                       readByOthers: Self.readByOthers(summary, me: me),
                                       othersTyping: !typing.subtracting([me]).isEmpty))
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
