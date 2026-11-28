import AppKit
public import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextWakeups

/// A view whose settled grid goes to the PTY owner (`DaemonTerminalIO`).
@MainActor public protocol ResizeTarget: AnyObject {
    func applySettled(_ size: CellSize)
    /// The daemon has not echoed this view's last grid yet.
    var awaitsEcho: Bool { get }
}

/// Sends terminal grid changes to the daemon only once a view's size has
/// settled (architecture.md 4: resize at animation end). Layout springs,
/// sidebar width animations and divider drags change pane sizes every frame,
/// so reports are held until three frames pass unchanged. A live window
/// resize is the exception: the person's pointer is on the edge and the
/// text must follow it, so each new grid goes the next frame (cx-sqj3h).
public final class ResizeCoordinator {
    public static let shared = ResizeCoordinator()
    public static let settleFrames = 3

    private var settle = ResizeSettle<ObjectIdentifier, CellSize>(stableFrames: ResizeCoordinator.settleFrames)
    private var targets: [ObjectIdentifier: any ResizeTarget] = [:]
    /// Pane sizes span windows, so the settle count runs on the app scheduler.
    public init() {}

    private lazy var frames = FrameClient(owner: "ResizeCoordinator.settle", isAnimation: false, on: .app) { [weak self] _ in
        self?.tick() ?? false
    }

    public func submit(_ io: any ResizeTarget, size: CellSize) {
        let key = ObjectIdentifier(io)
        targets[key] = io
        settle.submit(key, size: size)
        startLink()
    }

    public func cancel(_ io: any ResizeTarget) {
        let key = ObjectIdentifier(io)
        settle.cancel(key)
        targets[key] = nil
    }

    private func startLink() {
        frames.activate()
    }

    /// One frame; false once every size settled.
    public func tick() -> Bool {
        let live = Motion.isLiveResizing
        settle.stableFrames = live ? 1 : Self.settleFrames
        for (key, size) in settle.tick() {
            // Mid-drag, each terminal has one grid in flight: every grid rebuilds the surface
            // from a replay, so the next one waits for the daemon's echo (or the drag's end).
            if live, targets[key]?.awaitsEcho == true {
                settle.submit(key, size: size)
                continue
            }
            targets.removeValue(forKey: key)?.applySettled(size)
        }
        return !settle.isIdle
    }
}
