import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWakeups

/// A view whose settled grid goes to the PTY owner (`DaemonTerminalIO`).
@MainActor protocol ResizeTarget: AnyObject {
    func applySettled(_ size: CellSize)
}

/// Sends terminal grid changes to the daemon only once a view's size has
/// settled (architecture.md 4: resize at animation end). Layout springs,
/// sidebar width animations, divider drags, and live window resizes all
/// change pane sizes every frame; each daemon resize rebuilds the surface
/// from a replay, so reports are held until two frames pass unchanged.
final class ResizeCoordinator {
    static let shared = ResizeCoordinator()
    static let settleFrames = 3

    private var settle = ResizeSettle<ObjectIdentifier, CellSize>(stableFrames: ResizeCoordinator.settleFrames)
    private var targets: [ObjectIdentifier: any ResizeTarget] = [:]
    /// Pane sizes span windows, so the settle count runs on the app scheduler.
    private lazy var frames = FrameClient(owner: "ResizeCoordinator.settle", isAnimation: false, on: .app) { [weak self] _ in
        self?.tick() ?? false
    }

    func submit(_ io: any ResizeTarget, size: CellSize) {
        let key = ObjectIdentifier(io)
        targets[key] = io
        settle.submit(key, size: size)
        startLink()
    }

    func cancel(_ io: any ResizeTarget) {
        let key = ObjectIdentifier(io)
        settle.cancel(key)
        targets[key] = nil
    }

    private func startLink() {
        frames.activate()
    }

    /// One frame; false once every size settled.
    func tick() -> Bool {
        for (key, size) in settle.tick() {
            targets.removeValue(forKey: key)?.applySettled(size)
        }
        return !settle.isIdle
    }
}
