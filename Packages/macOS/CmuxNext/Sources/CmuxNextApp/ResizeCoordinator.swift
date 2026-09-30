import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWakeups

/// Sends terminal grid changes to the daemon only once a view's size has
/// settled (architecture.md 4: resize at animation end). Layout springs,
/// sidebar width animations, divider drags, and live window resizes all
/// change pane sizes every frame; each daemon resize rebuilds the surface
/// from a replay, so reports are held until two frames pass unchanged.
final class ResizeCoordinator {
    static let shared = ResizeCoordinator()

    private var settle = ResizeSettle<ObjectIdentifier, CellSize>(stableFrames: 3)
    private var targets: [ObjectIdentifier: DaemonTerminalIO] = [:]
    /// Pane sizes span windows, so the settle count runs on the app scheduler.
    private lazy var frames = FrameClient(owner: "ResizeCoordinator.settle", on: .app) { [weak self] _ in
        self?.tick() ?? false
    }

    func submit(_ io: DaemonTerminalIO, size: CellSize) {
        let key = ObjectIdentifier(io)
        targets[key] = io
        settle.submit(key, size: size)
        startLink()
    }

    func cancel(_ io: DaemonTerminalIO) {
        let key = ObjectIdentifier(io)
        settle.cancel(key)
        targets[key] = nil
    }

    private func startLink() {
        frames.activate()
    }

    /// One frame; false once every size settled.
    private func tick() -> Bool {
        for (key, size) in settle.tick() {
            targets.removeValue(forKey: key)?.applySettled(size)
        }
        return !settle.isIdle
    }
}
