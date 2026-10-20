import AppKit
import CmuxNextDesign
public import CmuxNextDaemon
import CmuxNextWakeups

/// A view whose settled grid goes to the PTY owner (`DaemonTerminalIO`).
@MainActor public protocol ResizeTarget: AnyObject {
    func applySettled(_ size: CellSize)
    /// The daemon has not echoed this view's last grid yet.
    var awaitsEcho: Bool { get }
}

/// Sends terminal grid changes to the daemon the next frame, with at most one
/// grid in flight per terminal (perf I7; Lawrence 2026-10-17: everything in a
/// drag is real time). A divider drag, a live window resize, a sidebar slide
/// or a layout spring changes a pane's size every frame, and the text reflows
/// with it. Every daemon resize reflows the PTY and echoes a rebuilt screen,
/// so while a terminal's last grid has not echoed its next one waits, and the
/// newest size (never the ones in between) goes the frame the echo comes: the
/// daemon never queues stale sizes. An echo that does not come within
/// `echoWaitFrames` (a refused or lost resize) stops holding the newest size.
public final class ResizeCoordinator {
    public static let shared = ResizeCoordinator()
    /// Frames a size waits for the echo of the grid before it.
    public static let echoWaitFrames = 30
    /// Grids sent to the daemon (`debug.window_transition`).
    public static var sent: UInt64 = 0

    private var settle = ResizeSettle<ObjectIdentifier, CellSize>(stableFrames: 1)
    private var targets: [ObjectIdentifier: any ResizeTarget] = [:]
    private var waited: [ObjectIdentifier: Int] = [:]
    /// Whether every size waits: a full screen enter or exit
    /// (`Motion.isFullScreenTransitioning`). AppKit animates a snapshot to
    /// the final size, so no in-between size shows; each one the daemon
    /// applied was a PTY reflow and a rebuilt screen for nothing, on the
    /// main thread the animation needs (fullscreen-lag). The newest size
    /// goes the frame after it ends. A drag stays real time (it does not hold).
    private let holds: () -> Bool
    /// Pane sizes span windows, so the frames run on the app scheduler.
    /// - Parameter holds: Whether sizes wait this frame; nil (the app) holds
    ///   during full screen transitions, tests pass their own.
    public init(holds: (() -> Bool)? = nil) {
        self.holds = holds ?? { Motion.isFullScreenTransitioning }
    }

    private lazy var frames = FrameClient(owner: "ResizeCoordinator.settle", isAnimation: false, on: .app) { [weak self] _ in
        self?.tick() ?? false
    }

    public func submit(_ io: any ResizeTarget, size: CellSize) {
        let key = ObjectIdentifier(io)
        targets[key] = io
        settle.submit(key, size: size)
        frames.activate()
    }

    public func cancel(_ io: any ResizeTarget) {
        let key = ObjectIdentifier(io)
        settle.cancel(key)
        targets[key] = nil
        waited[key] = nil
    }

    /// One frame; false once every size went.
    public func tick() -> Bool {
        // Held sizes keep waiting; the frames keep running until it ends.
        if holds() { return !settle.isIdle }
        for (key, size) in settle.tick() {
            if targets[key]?.awaitsEcho == true, waited[key, default: 0] < Self.echoWaitFrames {
                waited[key, default: 0] += 1
                settle.submit(key, size: size)
                continue
            }
            waited[key] = nil
            guard let target = targets.removeValue(forKey: key) else { continue }
            Self.sent &+= 1
            target.applySettled(size)
        }
        return !settle.isIdle
    }
}
