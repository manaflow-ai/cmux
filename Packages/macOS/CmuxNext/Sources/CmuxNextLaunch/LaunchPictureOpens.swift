import CoreGraphics

/// Opens from another app (a link, a file, Handoff, the Finder service) while the launch window shows its saved
/// picture (p08-startup-096, plans/cmux-next/chrome-parity/p08-startup.md, task 096): they wait for the pane they land
/// in, never for startup completion, and never build the window in their own turn.
///
/// - An open that comes before the window's build reached its focused pane is held (``holds(_:)``): from
///   `launch_picture_shown` (the app runs its waiting opens again then) or the moment it arrives, the build raises as
///   for a key (``LaunchWindowBuild/whenOpenReady(_:)``), so the focused pane is the first pane built, and the open
///   goes right after it shows. With no picture after all (none in time, a mismatch, the window closed first) it goes
///   once the window is built on today's path.
/// - The open lands in a pane (``opened(in:)``): that pane's part of the picture drops at once, as it shows what the
///   pane showed before the open. An open whose pane has no part of its own (the picture shows another page or
///   layout there) takes the whole picture away.
///
/// Chrome keeps a launch's URLs until its first browser window exists, then opens them as tabs the person asked for
/// (`StartupBrowserCreator::ProcessCmdLineImpl`, chrome/browser/ui/startup/startup_browser_creator.cc;
/// `AppController`'s `_startupUrls`, chrome/browser/app_controller_mac.mm), and its startup paint preview leaves once
/// the tab under it changes (chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreview.java).
///
/// ```swift
/// let opens = LaunchPictureOpens(phase: phase)
/// if opens.holds({ flush() }) { return pending.append(route) }   // the open waits for its pane
/// deliver(route, to: pane)
/// opens.opened(in: pane)                                          // its part of the picture drops
/// // once the window's build exists (`LaunchWindowBuild`):
/// opens.buildStarted(build)
/// ```
@MainActor
public final class LaunchPictureOpens {
    /// One held open's wake-up: it may be woken by the build and by the phase, and runs once.
    @MainActor private final class Wake {
        private var ready: (@MainActor () -> Void)?

        init(_ ready: @escaping @MainActor () -> Void) {
            self.ready = ready
        }

        func run() {
            guard let ready else { return }
            self.ready = nil
            ready()
        }
    }

    /// The launch window's picture phase this hold serves.
    public let phase: LaunchPicturePhase
    private weak var build: LaunchWindowBuild?
    /// Opens held before the build started: they raise it once it does.
    private var waiting: [Wake] = []

    /// - Parameter phase: The launch window's picture phase, from its start (the picture's read may still run).
    public init(phase: LaunchPicturePhase) {
        self.phase = phase
        phase.whenBuilt { [weak self] in self?.waiting = [] }
    }

    /// Whether an open must wait for the launch window: true while the picture phase runs and the window's focused
    /// pane is not shown yet. `ready` then runs once, when the open may go: right after the focused pane shows (the
    /// build raised for it), or once the window is built when no picture shows after all.
    public func holds(_ ready: @escaping @MainActor () -> Void) -> Bool {
        guard !phase.isBuilt, build?.isOpenReady != true else { return false }
        let wake = Wake(ready)
        phase.whenBuilt { wake.run() }
        if let build {
            build.whenOpenReady { wake.run() }
        } else {
            waiting.append(wake)
        }
        return true
    }

    /// The window's build behind the picture started (``LaunchWindowBuild/start()``): the opens held before it raise
    /// it now.
    public func buildStarted(_ build: LaunchWindowBuild) {
        self.build = build
        let held = waiting
        waiting = []
        for wake in held { build.whenOpenReady { wake.run() } }
    }

    /// An open landed in `pane` while the picture may still be over it: the part over the pane drops now, or the
    /// whole picture goes when no part of its own covers the pane. Nothing once the picture left.
    public func opened(in pane: any LaunchWindowPane) {
        guard let picture = phase.picture, let regions = phase.regions else { return }
        let area = pane.launchArea(in: picture)
        guard area.isEmpty || !regions.drop(at: CGPoint(x: area.midX, y: area.midY)) else { return }
        phase.remove()
    }
}
