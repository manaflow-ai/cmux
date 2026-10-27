import CmuxNextWakeups

/// What a session keeps for its hidden surface's release (``TerminalSurfaceRelease``).
@MainActor
final class TerminalSurfaceReleaseState {
    let policy: TerminalSurfaceRelease
    var dormancy = TerminalSurfaceDormancy()
    /// The hidden grace. Nobody waits for it: `background`.
    let deadline: MainDeadline
    /// The released surface's last presented frame, volatile until the terminal shows again.
    var frame: TerminalLastFrame?
    var releases = 0
    var rebuilds = 0

    init(policy: TerminalSurfaceRelease, deadlines: MainDeadlineScheduler) {
        self.policy = policy
        deadline = MainDeadline(owner: "TerminalSession.surfaceRelease", workClass: .background, scheduler: deadlines)
    }
}

// A hidden terminal holds no app surface (p01-process-140): after the grace its Ghostty surface goes and a
// stand-in with none takes its place; shown again, a fresh surface is rebuilt from the owner's whole screen.
extension TerminalSession {
    /// The surface is released: a stand-in with no Ghostty surface shows, and output is not parsed.
    public var isSurfaceReleased: Bool { surfaceRelease?.dormancy.state == .released }

    /// Surfaces released while hidden, and rebuilt when shown again (`debug.surfaces`).
    public var surfaceReleaseCounts: (releases: Int, rebuilds: Int) {
        (surfaceRelease?.releases ?? 0, surfaceRelease?.rebuilds ?? 0)
    }

    /// The released surface's last frame, for a warm-set eviction that keeps it (``TerminalLastFrames``).
    func takeReleasedFrame() -> TerminalLastFrame? {
        defer { surfaceRelease?.frame = nil }
        return surfaceRelease?.frame
    }

    /// Visibility, mirrors or the stream changed: starts or stops the grace, or rebuilds a released surface.
    func updateSurfaceRelease() {
        guard let release = surfaceRelease else { return }
        perform(release.dormancy.update(surfaceReleaseInputs), release)
    }

    /// The events loop's lane after a release or a rebuild (``TerminalEventRouter``).
    func laneHandoff() -> TerminalLaneHandoff {
        TerminalLaneHandoff(lane: surfaceView.lane, epoch: surfaceEpoch.current, released: isSurfaceReleased)
    }

    private var surfaceReleaseInputs: TerminalSurfaceDormancy.Inputs {
        // Only an owner that sends the whole screen again (the daemon, by a fresh attach) can rebuild it.
        TerminalSurfaceDormancy.Inputs(hidden: isRenderingSuspended && mirrorDemand == 0,
                                       rebuildable: io.resendsScreen && model.connection == .connected && !model.hasExited,
                                       pinned: holdsViewState)
    }

    /// The surface holds what the owner's screen does not: a selection, or a viewport scrolled back
    /// from the bottom (a rebuilt surface shows the bottom with nothing selected).
    private var holdsViewState: Bool {
        isSelectionPinned || surfaceView.hasSelection || model.scrollbar.map { !$0.showsBottom } == true
    }

    private func perform(_ step: TerminalSurfaceDormancy.Step, _ release: TerminalSurfaceReleaseState) {
        switch step {
        case .none: break
        case .startGrace:
            release.deadline.schedule(after: release.policy.grace) { [weak self] in self?.surfaceGraceEnded() }
        case .cancelGrace: release.deadline.cancel()
        case .release: releaseSurface(release)
        case .rebuild: rebuildSurface(release)
        }
    }

    /// The hidden grace ended (its deadline; tests call it to end the grace at once).
    func surfaceGraceEnded() {
        guard let release = surfaceRelease else { return }
        applyEvents() // the stream's latest status decides
        perform(release.dormancy.graceEnded(surfaceReleaseInputs), release)
    }

    /// Keeps the last frame (volatile, no copy), swaps in the stand-in, whose old surface is freed with its
    /// view, and stops the IO's reader feeding the old lane: output is dropped until the rebuild.
    private func releaseSurface(_ release: TerminalSurfaceReleaseState) {
        release.frame = TerminalLastFrame(of: self)
        swapSurface(makesSurface: false)
        surfaceEpoch.advance()
        outputLane.name(nil)
        release.releases += 1
    }

    /// In the show's turn: a fresh surface with the last frame painted over it until the owner's whole
    /// screen and the stream after it are parsed and drawn. The owner re-attaches for it whatever the
    /// stream did while released (an exited terminal's final screen too); the events loop drops content
    /// until it comes.
    private func rebuildSurface(_ release: TerminalSurfaceReleaseState) {
        let frame = release.frame
        release.frame = nil
        swapSurface()
        surfaceEpoch.advance()
        if let held = frame?.take() { frameHold.begin(lastFrame: held, over: surfaceView, in: view) }
        input.refresh()
        release.rebuilds += 1
    }
}
