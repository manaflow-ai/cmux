/// Where something opened from another app landed (``ExternalOpenQueue``'s `run`).
public enum ExternalOpenLanding {
    /// No pane to open in yet: the route waits for the next ``ExternalOpenQueue/flush()``. `then` runs once it is
    /// queued: a window made for it, whose content runs the queue in that turn.
    case waits(then: (@MainActor () -> Void)? = nil)
    /// It opened in this pane (a tab, a file, a link that kept the shown workspace): the launch picture's part over
    /// the pane drops.
    case pane(any LaunchWindowPane)
    /// A link moved the window to another workspace, page or window: the launch picture shows none of it.
    case elsewhere

    /// Where a `cmux://` link landed: in `focused`, the active window's focused pane after it ran, when it kept the
    /// window, workspace and page it showed; elsewhere when it moved them or left no pane.
    public init(link focused: (any LaunchWindowPane)?, keptPlace: Bool) {
        if keptPlace, let focused { self = .pane(focused) } else { self = .elsewhere }
    }
}

/// The queue of what opens from another app once the app's services exist (the app's `ExternalOpenController`): a
/// route runs now, or waits until a window has content (a cold launch by a link) or, under the launch picture, until
/// the pane it lands in shows (``LaunchPictureOpens``, p08-startup-096). Where it lands decides what of the launch
/// picture drops. ``LaunchOpenQueue`` keeps what comes before the services exist.
///
/// Chrome keeps a launch's URLs until its first browser window exists, then opens them
/// (`StartupBrowserCreator::ProcessCmdLineImpl`, chrome/browser/ui/startup/startup_browser_creator.cc).
///
/// ```swift
/// let queue = ExternalOpenQueue<Route>(launchPicture: { windows.launchPicture },
///                                      hasTarget: { windows.active?.focusedPane != nil }) { route in run(route) }
/// queue.open(route)          // what macOS handed the app
/// queue.flush()              // a window showed its content, or the launch picture shows
/// queue.launchBuildStarted(build)
/// ```
@MainActor
public final class ExternalOpenQueue<Route> {
    /// The routes waiting, oldest first.
    public private(set) var pending: [Route] = []
    private let launchPicture: @MainActor () -> LaunchPicturePhase?
    private let hasTarget: @MainActor () -> Bool
    private let run: @MainActor (Route) -> ExternalOpenLanding
    private var launchOpens: LaunchPictureOpens?

    /// - Parameters:
    ///   - launchPicture: The launch window's picture phase while it runs (the window manager's), else nil.
    ///   - hasTarget: Whether a window has a focused pane to open in: the waiting routes run then.
    ///   - run: Runs one route now, in the active window, and says where it landed.
    public init(launchPicture: @escaping @MainActor () -> LaunchPicturePhase?, hasTarget: @escaping @MainActor () -> Bool,
                run: @escaping @MainActor (Route) -> ExternalOpenLanding) {
        self.launchPicture = launchPicture
        self.hasTarget = hasTarget
        self.run = run
    }

    nonisolated deinit {}

    /// Runs `route` now, or keeps it until it may run.
    public func open(_ route: Route) {
        // The launch window's pane is not built yet: the open waits for it, never building the window in this turn.
        guard !holdsForLaunchPicture() else { return pending.append(route) }
        let opens = launchOpens
        switch run(route) {
        case .waits(let then):
            pending.append(route)
            then?()
        case .pane(let pane): opens?.opened(in: pane)  // the picture over the pane shows what it showed before the open
        case .elsewhere: opens?.openedElsewhere()
        }
    }

    /// A window installed its content, the launch window's picture shows (`launch_picture_shown`), or the pane the
    /// launch picture held an open for is shown: runs what waited, once nothing holds it.
    public func flush() {
        guard !pending.isEmpty, !holdsForLaunchPicture(), hasTarget() else { return }
        let routes = pending
        pending = []
        for route in routes { open(route) }
    }

    /// The launch window's build behind its picture started: an open held for it raises it.
    public func launchBuildStarted(_ build: LaunchWindowBuild) {
        currentLaunchOpens()?.buildStarted(build)
    }

    private func holdsForLaunchPicture() -> Bool {
        currentLaunchOpens()?.holds() == true
    }

    /// The hold of the launch picture that shows now; nil with none.
    private func currentLaunchOpens() -> LaunchPictureOpens? {
        guard let phase = launchPicture() else {
            launchOpens = nil
            return nil
        }
        if let opens = launchOpens, opens.phase === phase { return opens }
        let opens = LaunchPictureOpens(phase: phase) { [weak self] in self?.flush() }
        launchOpens = opens
        return opens
    }
}
