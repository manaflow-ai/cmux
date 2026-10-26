public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextWakeups

/// The launch window while its saved picture is its first frame (p08-startup-059, plans/cmux-next/chrome-parity/
/// p08-startup.md section 3A, P2): the window at its saved frame, its live `WindowMaterialView` and one
/// ``LaunchPictureView``. Nothing else of the window exists in that frame; once it is committed the window's
/// controller is built in the same window behind the picture (an afterFirstFrame post), and the picture leaves when
/// the launch reveal shows every region, at most ``bound`` later.
///
/// Chrome shows the first restored tab's saved capture until its live page paints and lets the tab load as usual
/// when the capture is not ready (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/
/// StartupPaintPreviewHelper.java).
///
/// The steps, each run once, in this order:
/// 1. ``start(_:on:mainWork:then:)``: waits for the picture's read (a lane task; the reply is a posted main task)
///    at most ``wait`` (a `MainDeadline`). The main thread never waits.
/// 2. The caller takes the picture and matches its meta; then ``show(_:in:scope:present:startup:build:)``, or
///    ``skip()`` for today's path (no picture, none in time, another window's, a mismatch).
/// 3. ``adopt(root:reveal:)``: the controller was built in the window; the picture goes over its root.
///
/// ```swift
/// let phase = LaunchPicturePhase(deadlines: deadlines) { DebugTimings.markLaunch($0) }
/// phase.start({ _ = await pictures.frontFinished() }, on: work, mainWork: mainWork) { _ in
///     guard let front = pictures.takeFront(), matches(front) else { return phase.skip(); makeController() }
///     phase.show(front.image, in: window, scope: scope, present: { window.orderFront(nil) }, startup: startup) {
///         phase.adopt(root: makeController(in: window).root, reveal: reveal)
///     }
/// }
/// ```
@MainActor
public final class LaunchPicturePhase {
    /// How long the first window waits for its picture's decode before it opens on today's path.
    public static let wait: Duration = .milliseconds(40)
    /// How long the picture may stay over the live window when a region never reports its first content.
    public static let bound: Duration = .seconds(2)

    /// The window showing the picture, from ``show(_:in:scope:present:startup:build:)`` until the picture left.
    public private(set) weak var window: NSWindow?
    /// The picture on screen; nil before it shows and once it left.
    public private(set) var picture: LaunchPictureView?
    /// The window's controller exists (``adopt(root:reveal:)`` or ``skip()``): work that adopts it may run.
    public private(set) var isBuilt = false

    private let waitDeadline: MainDeadline
    private let boundDeadline: MainDeadline
    private let mark: (String) -> Void
    private var decide: (@MainActor (Bool) -> Void)?
    private var builtWaiters: [@MainActor () -> Void] = []

    /// - Parameters:
    ///   - deadlines: The app's deadline scheduler: the wait and the bound are `MainDeadline`s on it.
    ///   - mark: Records a launch mark (`launch_picture_shown`, `first_window_frame_committed`, `launch_picture_removed`).
    public init(deadlines: MainDeadlineScheduler, mark: @escaping (String) -> Void) {
        waitDeadline = MainDeadline(owner: "LaunchPicturePhase.wait", workClass: .visible, scheduler: deadlines)
        boundDeadline = MainDeadline(owner: "LaunchPicturePhase.bound", workClass: .visible, scheduler: deadlines)
        self.mark = mark
    }

    /// Waits for `finished` (the picture's read) at most ``wait``: `decide` runs once, with true in the posted turn
    /// after the read ended in time, else with false at the deadline. A later call does nothing.
    public func start(_ finished: @escaping @Sendable () async -> Void, on work: BackgroundWork, mainWork: MainWorkScheduler,
                      then decide: @escaping @MainActor (_ inTime: Bool) -> Void) {
        guard self.decide == nil, !isBuilt, picture == nil else { return }
        self.decide = decide
        waitDeadline.schedule(after: Self.wait) { [weak self] in self?.decided(inTime: false) }
        work.task(.userBlocking) { [self] in
            await finished()
            mainWork.postFromAnyThread(.visible, owner: "LaunchPicturePhase.read") { self.decided(inTime: true) }
        }
    }

    /// Whether ``start(_:on:mainWork:then:)`` runs and has not decided yet.
    public var isWaiting: Bool { decide != nil }

    func decided(inTime: Bool) {
        guard let decide else { return }
        self.decide = nil
        waitDeadline.cancel()
        decide(inTime)
    }

    /// Makes `image` the whole of `window`'s first frame: the window's backdrop (material, tint, blur) in `scope`
    /// and the picture over it, ordered in by `present`. When that frame is committed: the launch's first frame
    /// (`first_window_frame_committed`, `startup`'s first-frame ref), and `build` posted as afterFirstFrame work
    /// (run at once with no scheduler, tests).
    public func show(_ image: CGImage, in window: NSWindow, scope: ThemeScope, present: () -> Void, startup: StartupScheduler?,
                     build: @escaping @MainActor @Sendable () -> Void) {
        guard picture == nil, !isBuilt else { return }
        let picture = LaunchPictureView(image: image, scale: window.backingScaleFactor)
        window.install(kind: .main, content: WindowSurfaceView(content: picture), scope: scope)
        (self.window, self.picture) = (window, picture)
        present()
        mark("launch_picture_shown")
        CATransaction.setMainCompletion { [weak self] in
            guard let self, !isBuilt else { return }
            mark("first_window_frame_committed")
            guard let startup else { return build() }
            startup.post(.afterFirstFrame, "LaunchPicturePhase.build", on: .main, build)
            startup.firstFrameCommitted()
        }
    }

    /// No picture shows: the window opens on today's path, its controller made by the caller now.
    public func skip() {
        guard !isBuilt else { return }
        decide = nil
        waitDeadline.cancel()
        built()
    }

    /// The controller was built in the picture's window: the picture stays over `root` (its last subview) until
    /// `reveal` shows every region, or ``bound``.
    public func adopt(root: NSView, reveal: LaunchReveal) {
        guard let picture, !isBuilt else { return }
        picture.frame = root.bounds
        picture.autoresizingMask = [.width, .height]
        root.addSubview(picture)
        built()
        reveal.whenReady(.sidebar) { [weak self] in
            reveal.whenReady(.tabs) { reveal.whenReady(.pane) { self?.remove() } }
        }
        boundDeadline.schedule(after: Self.bound) { [weak self] in self?.remove() }
    }

    /// The picture leaves in one frame (p08-startup-060 takes it out region by region through the Motion gate).
    public func remove() {
        guard let picture else { return }
        self.picture = nil
        window = nil
        boundDeadline.cancel()
        picture.removeFromSuperview()
        mark("launch_picture_removed")
    }

    /// Runs `work` once the window has its controller: at once when it has, or when no picture is in its way.
    public func whenBuilt(_ work: @escaping @MainActor () -> Void) {
        if isBuilt { work() } else { builtWaiters.append(work) }
    }

    private func built() {
        isBuilt = true
        let waiting = builtWaiters
        builtWaiters = []
        for work in waiting { work() }
    }
}
