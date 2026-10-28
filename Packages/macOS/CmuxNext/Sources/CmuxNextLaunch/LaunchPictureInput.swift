public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups

/// Input while the first window shows its launch picture (p08-startup-061): the edges of the picture phase
/// (``LaunchPicturePhase``) reach the key router's stand-in buffer (``LaunchPictureKeys``), and a click on a part of
/// the picture still over the live root (``LaunchPictureRegions``) is held (``LaunchPictureClicks``).
/// - `launch_picture_shown` (this init): the buffer begins for the window; a key or a click raises the window's
///   build behind the picture (``LaunchWindowBuild/raise()``, a userBlocking post, never in the input's turn).
/// - The pane region's first content: the buffer gives the waiting keys to their terminals.
/// - A part leaves at its region's first content, or at the picture's bound (``LaunchPicturePhase/bound``, the hard
///   limit of every wait here): its held clicks go again at the same window point, now to the live view under it,
///   unless what the window shows or its size changed since (then they are dropped and counted). A click is never
///   lost to a timer (audit B10): ``clickStage`` counts the clicks sent and dropped and the longest wait.
/// - The picture left (``finish()``): a click still waiting goes the same way, and the buffer ends for the window, in
///   its own turn (the picture can leave inside the root's layout, where no key is delivered).
///
/// Chrome's startup paint preview does the same with a tap on the capture: it waits for the live tab, which gets it
/// once it painted (`PlayerCompositorDelegateImpl`,
/// chrome/android/java/src/org/chromium/chrome/browser/paint_preview/TabbedPaintPreview.java).
///
/// ```swift
/// let input = LaunchPictureInput(window: id, shell: window, keys: keys, reveal: reveal, mainWork: mainWork) { shownModel() }
/// phase.whenRemoved { input.finish() }
/// // once the controller's root is under the picture:
/// input.holdClicks(on: picture, regions: regions)
/// input.build = build
/// ```
@MainActor
public final class LaunchPictureInput {
    /// The window's build behind the picture, once it started: a key or a click raises it.
    public weak var build: LaunchWindowBuild?

    private let window: String
    private weak var keys: LaunchPictureKeys?
    private let mainWork: MainWorkScheduler
    private let stamp: @MainActor () -> String?
    private let resend: @MainActor (NSEvent) -> Void
    private let now: @MainActor () -> ContinuousClock.Instant
    private var clicks = LaunchPictureClicks()
    private weak var picture: LaunchPictureView?
    private var isFinished = false

    /// - Parameters:
    ///   - window: The window's stable id (`WindowState.id`).
    ///   - shell: The window showing the picture.
    ///   - keys: The key router's stand-in buffer.
    ///   - reveal: The launch's regions.
    ///   - mainWork: The app's main-thread scheduler.
    ///   - resend: Sends a held mouse event again through the app, behind the events already queued.
    ///   - now: The clock's reading (tests pass their own).
    ///   - stamp: What the window shows in the model now (its workspace or page): a held click whose stamp changed
    ///     before its part went live is dropped.
    public init(window: String, shell: NSWindow?, keys: LaunchPictureKeys, reveal: LaunchReveal, mainWork: MainWorkScheduler,
                resend: @escaping @MainActor (NSEvent) -> Void = { NSApp.postEvent($0, atStart: false) },
                now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
                stamp: @escaping @MainActor () -> String?) {
        self.window = window
        self.keys = keys
        self.mainWork = mainWork
        self.stamp = stamp
        self.resend = resend
        self.now = now
        keys.begin(window: window, shell: shell) { [weak self] _ in self?.build?.raise() }
        reveal.whenProduced(.pane) { [weak keys] in keys?.retry() }
    }

    /// Clicks still waiting for their part.
    public var heldClicks: Int { clicks.count }

    /// The held clicks' measured stage: how many went to the live view, how many were dropped, and the longest wait.
    public struct ClickStage: Sendable, Equatable {
        public var delivered = 0
        public var dropped = 0
        public var longestWait: Duration = .zero
    }

    /// The held clicks so far (`debug` readers, tests).
    public private(set) var clickStage = ClickStage()

    /// The picture is over the live root, masked by `regions`: a click where it still shows waits for that part.
    public func holdClicks(on picture: LaunchPictureView, regions: LaunchPictureRegions) {
        guard !isFinished else { return }
        self.picture = picture
        picture.takesClick = { [weak regions] point in regions?.covers(point) == true }
        picture.pressed = { [weak self, weak regions] event, point in
            guard let self, let holder = regions?.holder(at: point) else { return }
            clicks.press(event, part: holder, stamp: shown(), at: now())
            build?.raise()
        }
        picture.released = { [weak self] up in self?.release(up) }
        regions.partLeft = { [weak self] holder, drawn in self?.partLeft(holder, drawn: drawn) }
    }

    /// The picture left (every region drew, the bound, its window closed): the clicks it held are dropped, and the
    /// window's key buffer ends in its own turn.
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        // The picture is gone: the live root is under every click still waiting (normally none: each part's leave sent them).
        for part in clicks.waitingParts { partLeft(part, drawn: false) }
        if let picture {
            picture.takesClick = nil
            picture.pressed = nil
        }
        let window = window
        mainWork.post(.userBlocking, owner: "LaunchPictureInput.finish") { [weak keys] in keys?.end(window: window) }
    }

    /// What the window shows and its size: a held click whose window changed either means another place now.
    private func shown() -> String? {
        stamp().map { "\($0) \(picture?.bounds.size ?? .zero)" }
    }

    private func release(_ up: NSEvent) {
        for event in clicks.release(up) { resend(event) }
    }

    /// `holder`'s part left: drawn (its region's first content) or at the bound (`drawn` false). Either way the live
    /// root shows there now, so its clicks go to it: the person clicked that place, and a drop would lose the click.
    private func partLeft(_ holder: String, drawn: Bool) {
        let outcome = clicks.partDidGoLive(holder, stamp: shown(), at: now())
        clickStage.delivered += outcome.delivered
        clickStage.dropped += outcome.dropped
        clickStage.longestWait = max(clickStage.longestWait, outcome.longestWait)
        for event in outcome.send { resend(event) }
    }
}
