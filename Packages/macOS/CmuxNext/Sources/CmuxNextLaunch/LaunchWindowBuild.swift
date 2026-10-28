public import AppKit
public import CmuxNextDesign

/// The launch window as ``LaunchWindowBuild`` builds it behind its picture (the app's window controller).
@MainActor
public protocol LaunchBuiltWindow: AnyObject {
    /// Mounts the shown workspace's layout and its panes' tab strips, no pane's content yet (the build shows each
    /// in its own slice). Returns the panes on screen, the focused one first, then in layout order.
    func mountLaunchStrips() -> [any LaunchWindowPane]
    /// The build is over: the window follows its workspace from now on.
    func goLive()
}

/// One pane of the launch window as ``LaunchWindowBuild`` shows it (the app's pane controller).
@MainActor
public protocol LaunchWindowPane: AnyObject {
    /// Shows the pane's selected content now, its slice: a terminal attaches here.
    func showForLaunch()
    /// Runs `drawn` once the content ``showForLaunch()`` showed draws its first meaningful frame: a terminal's first
    /// frame after its first content (the daemon's snapshot or replay) is applied, a page's first contentful paint,
    /// native content at the commit that shows it, at once with nothing to show. Returns what cancels the wait.
    func whenLaunchContentDrawn(_ drawn: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)?
    /// The pane's area in `picture`'s coordinates; empty once it left the window.
    func launchArea(in picture: NSView) -> CGRect
}

/// Builds the launch window's live views behind its picture, slice by slice
/// (plans/cmux-next/chrome-parity/p08-startup.md section 3A, P4), each slice its own afterFirstFrame post (budgeted
/// per frame at `MainWorkClass.visible`, behind input), so no main turn builds the whole window:
///
/// 1. The window's controller with its sidebar rows (the caller's post, before ``start()``).
/// 2. ``tabStrips``: the shown workspace's layout and every pane's tab strip, no content.
/// 3. ``focusedPane``: the focused pane's content; its terminal attaches first.
/// 4. ``visiblePane``, once per other pane on screen, in layout order.
/// 5. ``live``: the window follows its workspace; no part comes later (``LaunchPictureRegions/seal()``).
///
/// Each pane gets a part of the picture over its area when its strip is mounted; the part leaves at that pane's own
/// first meaningful content, once the launch reveal shows its strip and content views (so a part never uncovers a
/// held view). Chrome builds a restored window's tabs the same way: the active tab first, the others' loads after it
/// (chrome/browser/sessions/session_restore.cc, `SessionRestoreImpl::RestoreTabsToBrowser`;
/// chrome/browser/sessions/tab_loader.cc).
///
/// ```swift
/// let build = LaunchWindowBuild(window: controller, regions: regions, reveal: reveal, post: { name, work in
///     startup.post(.afterFirstFrame, name, on: .main, work)
/// }) { phase.buildFinished() }
/// build.start()
/// ```
@MainActor
public final class LaunchWindowBuild {
    /// Posts one slice as afterFirstFrame main work (`StartupScheduler.post`).
    public typealias Post = @MainActor (_ name: StaticString, _ work: @escaping @MainActor @Sendable () -> Void) -> Void

    /// The slices' names in the startup log, the signposts and the watchdog.
    public nonisolated static let tabStrips: StaticString = "LaunchWindow.tabStrips"
    public nonisolated static let focusedPane: StaticString = "LaunchWindow.focusedPane"
    public nonisolated static let visiblePane: StaticString = "LaunchWindow.visiblePane"
    public nonisolated static let live: StaticString = "LaunchWindow.live"
    /// The strips and the focused pane run early for a key or a click on the picture (``raise()``).
    public nonisolated static let raised: StaticString = "LaunchWindow.raised"

    private weak var window: (any LaunchBuiltWindow)?
    private weak var regions: LaunchPictureRegions?
    private let reveal: LaunchReveal
    private let post: Post
    private let urgent: Post
    private var done: (@MainActor () -> Void)?
    private var stripsMounted = false
    private var shown: Set<Int> = []
    private var isRaised = false
    private var panes: [any LaunchWindowPane] = []
    private var parts: [LaunchPictureRegions.Part] = []
    /// The panes' first-content waits still running.
    private var waits: [@MainActor () -> Void] = []

    /// Every slice ran (or the window went first).
    public private(set) var isDone = false

    /// - Parameters:
    ///   - window: The window, its controller built in the picture's window.
    ///   - regions: The picture's regions (``LaunchPicturePhase/adopt(root:reveal:)``).
    ///   - reveal: The launch's regions: a pane's part waits for its strip and content views to show.
    ///   - post: Posts one slice.
    ///   - urgent: Posts the raised slice (``raise()``) as input-class main work for the next frame; nil, as `post`.
    ///   - done: Runs once, after the last slice.
    public init(window: any LaunchBuiltWindow, regions: LaunchPictureRegions, reveal: LaunchReveal, post: @escaping Post,
                urgent: Post? = nil, done: @escaping @MainActor () -> Void) {
        self.window = window
        self.regions = regions
        self.reveal = reveal
        self.post = post
        self.urgent = urgent ?? post
        self.done = done
    }

    /// Posts the first slice. A slice keeps the build until it runs.
    public func start() {
        post(Self.tabStrips) { [self] in mountStrips() }
    }

    /// A key or a click waits on the picture (``LaunchPictureInput``): the tab strips and the focused
    /// pane are built in one `urgent` post, never in the input's turn, ahead of the frame-budgeted slices; each slice
    /// still runs once. Later calls do nothing.
    public func raise() {
        guard !isDone, !isRaised else { return }
        isRaised = true
        urgent(Self.raised) { [self] in
            mountStrips()
            show(0)
        }
    }

    /// The picture left (the bound, its window closed or resized): the panes' waits end. Slices still posted run.
    public func stop() {
        let waiting = waits
        waits = []
        for cancel in waiting { cancel() }
    }

    private func mountStrips() {
        guard !stripsMounted else { return }
        stripsMounted = true
        guard !isDone, let window, let regions else { return goLive() }
        panes = window.mountLaunchStrips()
        parts = panes.map { pane in
            regions.add { [weak pane] picture in pane?.launchArea(in: picture) ?? .zero }
        }
        for index in panes.indices {
            post(index == 0 ? Self.focusedPane : Self.visiblePane) { [self] in show(index) }
        }
        post(Self.live) { [self] in goLive() }
    }

    private func show(_ index: Int) {
        guard !isDone, window != nil, panes.indices.contains(index), shown.insert(index).inserted else { return }
        let pane = panes[index], part = parts[index], reveal = reveal, regions = regions
        pane.showForLaunch()
        // The part leaves at the pane's own first content, never over a strip or content the reveal still holds clear.
        let cancel = pane.whenLaunchContentDrawn {
            reveal.whenReady(.tabs) { reveal.whenReady(.pane) { regions?.leave(part) } }
        }
        if let cancel { waits.append(cancel) }
    }

    private func goLive() {
        guard !isDone else { return }
        isDone = true
        (panes, parts) = ([], [])
        regions?.seal()
        window?.goLive()
        let done = done
        self.done = nil
        done?()
    }
}
