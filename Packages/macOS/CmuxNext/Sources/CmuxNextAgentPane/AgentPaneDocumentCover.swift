public import AppKit
import CmuxNextWakeups

/// What a chat that already drew shows while its page gets a new document: its last frame, until the new
/// document reports its first paint (`pane.painted`).
///
/// Leo, 2026-11-22 06:44Z: "also holy fuck idk why there was some sort of situation just now that compLETELY
/// blanked out this agent chat + the update notes", then 06:47Z: "i just saw the entire thing flash and then
/// re-render and then shift as it loaded in and expanded then collapsed tool calls". A web override reloaded
/// every chat at once, app health reloaded pages and ended their renderer, and under load each new document
/// took 12 to 70 s to load: the pane showed the page's empty document over the wallpaper the whole time. The
/// loading state covers only a pane's first document (``AgentPaneView/beginLoadingState()``); this covers
/// every later one, for every cause (``PageDocumentChange``): a reload asked for in either engine, app
/// health's reload and renderer restart, a crash retry, a web content process or Chromium renderer that
/// ended.
///
/// The picture is the page's own (``AgentPaneView/pageImage()``), taken when its document first draws, a
/// moment after the person's last click or key in it, and once more when a reload is asked for while the old
/// document still draws. With no picture of its size and look, the pane shows its loading state (page
/// background and the busy mark), never an unpainted page.
@MainActor
public final class AgentPaneDocumentCover {
    /// Why the cover went up (``PageDocumentChange``, or a new document nobody announced).
    public enum Cause: String, Sendable {
        case reload
        case contentEnded = "content-ended"
        case rendererRestart = "renderer-restart"
        case newDocument = "new-document"
        /// The page's error boundary caught a render error (`pane.renderFailed`): its document draws nothing
        /// until the boundary's own retry reloads it.
        case renderFailed = "render-failed"
    }

    /// One recovery: from the cover going up to the new document's first paint report.
    public struct Recovery: Equatable, Sendable {
        public let cause: Cause
        public let milliseconds: Int
        /// Whether the page's picture stood in (else the loading state did).
        public let picture: Bool
    }

    /// The page's last frame, as ``AgentPaneView/pageImage()`` drew it.
    struct Frame {
        let image: NSImage
        let size: CGSize
        let appearance: NSAppearance.Name?
        let uptime: TimeInterval
    }

    /// The cover itself: the loading state's view, with the picture as its layer's contents.
    let view = AgentPaneLoadingView()
    private(set) var frame: Frame?
    /// Why the shown cover went up; nil while none shows.
    public private(set) var cause: Cause?
    private(set) var since: TimeInterval = 0
    public private(set) var showsPicture = false
    /// New documents committed since the cover went up: only their paint report ends it (the old
    /// document's late report would reveal the empty new one).
    private(set) var documentsSince = 0
    /// Every committed document: a picture whose capture spans one is of the wrong document.
    private(set) var documents = 0
    /// What the cover changed on the page, put back when it goes.
    var hidPage = false
    /// The page's renderer ended and no document committed since: its picture would be empty.
    var pageEnded = false
    var heldPageAway = false
    /// The last recoveries, newest last (tests, `debug.agent_pane`).
    public private(set) var recoveries: [Recovery] = []
    /// The NIGHTLY detector (`debug.agent_pane pacer`, its `blank_recovery`): covers put up by cause, renderer ends, and
    /// the times the pane showed a document that drew nothing (`blankReveals`: the give-up's old path; 0 is the bar).
    public private(set) var covers: [Cause: Int] = [:]
    public private(set) var rendererEnds = 0
    var giveUpsKept = 0
    public private(set) var blankReveals = 0
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Takes the page's picture; nil uses ``AgentPaneView/pageImage()`` (tests set it).
    var takePicture: (@MainActor (AgentPaneView) async -> NSImage?)?
    private(set) var capturing = false
    /// A capture a moment after the page drew or the person touched it.
    let captureTimer = DemandTimer(owner: "agent-pane.reload-cover.capture")
    private var lastCaptureUptime: TimeInterval = -.infinity
    /// A reload's cover whose new document never commits (a failed provisional load, a dropped Chromium
    /// navigation) ends after ``uncommittedLimit``: the old document still draws under it, and the stale picture
    /// would otherwise stay up for good. A commit after that puts the cover back up for the new document.
    let uncommittedTimer = DemandTimer(owner: "agent-pane.document-cover.uncommitted")
    var uncommittedLimit: Duration = .seconds(10)
    /// Reload covers ended because no new document committed (`debug.agent_pane pacer`).
    public private(set) var uncommittedEnds = 0

    /// How soon after a paint report or a gesture the picture is taken, and how often at most.
    static let captureDelay: Duration = .milliseconds(1500)
    static let captureInterval: TimeInterval = 5
    static let recoveriesKept = 16

    public var isShown: Bool { cause != nil }

    init() {
        // Clicks go through to the page under the picture: the composer takes them before the new document painted.
        view.passesInput = true
    }

    /// The picture for a cover of `size` in `appearance`, if the last frame was drawn that way.
    func picture(size: CGSize, appearance: NSAppearance.Name?) -> NSImage? {
        guard let frame, frame.size == size, frame.appearance == appearance else { return nil }
        return frame.image
    }

    /// Whether a capture may start now: none runs, the last is older than ``captureInterval`` (or `fresh`).
    func mayCapture(fresh: Bool) -> Bool {
        !capturing && (fresh || now() - lastCaptureUptime >= Self.captureInterval)
    }

    func captureStarted() -> Int {
        capturing = true
        lastCaptureUptime = now()
        return documents
    }

    /// A capture that started at document `serial` ended with `image` at `size`: kept when no new document
    /// committed meanwhile.
    @discardableResult
    func captureEnded(_ image: NSImage?, size: CGSize, appearance: NSAppearance.Name?, serial: Int) -> Bool {
        capturing = false
        guard let image, serial == documents, image.size == size, size.width > 0, size.height > 0 else { return false }
        frame = Frame(image: image, size: size, appearance: appearance, uptime: now())
        return true
    }

    /// Age of the last frame in ms, for the breadcrumb; nil with none.
    var frameAgeMilliseconds: Int? { frame.map { Int(((now() - $0.uptime) * 1000).rounded()) } }

    func began(_ cause: Cause, picture: Bool, afterCommit: Bool) {
        covers[cause, default: 0] += 1
        self.cause = cause
        since = now()
        showsPicture = picture
        documentsSince = afterCommit ? 1 : 0
    }

    func documentCommitted() {
        documents += 1
        pageEnded = false
        if isShown { documentsSince += 1 }
    }

    /// The page's picture stands in now (a fresh one landed over the loading state).
    func pictureShown() { if isShown { showsPicture = true } }

    /// Whether the shown cover is a reload's whose new document has not committed (the old one still draws).
    /// A render failure's cover waits on the boundary's reload the same way: a reload that never comes (a page whose
    /// retries back off past ``uncommittedLimit``) shows the page again, with its "Still loading" line.
    var waitsOnUncommittedReload: Bool { (cause == .reload || cause == .renderFailed) && documentsSince == 0 }

    func uncommittedEnded() { uncommittedEnds += 1 }

    func pageEndedNow() {
        pageEnded = true
        rendererEnds += 1
    }

    func gaveUp(kept: Bool) {
        if kept { giveUpsKept += 1 } else { blankReveals += 1 }
    }

    /// The detector's counts, for `debug.agent_pane pacer`'s `blank_recovery`.
    public var report: [String: Any] {
        [
            "covers": Dictionary(uniqueKeysWithValues: covers.map { ($0.key.rawValue, $0.value) }),
            "renderer_ends": rendererEnds, "uncommitted_ends": uncommittedEnds, "give_ups_kept": giveUpsKept, "blank_reveals": blankReveals,
            "shown": cause.map { $0.rawValue as Any } ?? NSNull(), "picture_age_ms": frameAgeMilliseconds.map { $0 as Any } ?? NSNull(),
            "recoveries": recoveries.map { ["cause": $0.cause.rawValue, "ms": $0.milliseconds, "picture": $0.picture] as [String: Any] },
        ]
    }

    /// The picture no longer fits (the pane resized): the loading state stands in.
    func droppedPicture() { showsPicture = false }

    /// The cover went; returns the recovery when the new document painted.
    @discardableResult
    func ended(painted: Bool) -> Recovery? {
        uncommittedTimer.cancel()
        guard let cause else { return nil }
        let recovery = Recovery(cause: cause, milliseconds: Int(((now() - since) * 1000).rounded()), picture: showsPicture)
        self.cause = nil
        documentsSince = 0
        showsPicture = false
        guard painted else { return nil }
        recoveries.append(recovery)
        if recoveries.count > Self.recoveriesKept { recoveries.removeFirst(recoveries.count - Self.recoveriesKept) }
        return recovery
    }
}
