import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import QuartzCore

/// Sends terminal grid changes to the daemon only once a view's size has
/// settled (architecture.md 4: resize at animation end). Layout springs,
/// sidebar width animations, divider drags, and live window resizes all
/// change pane sizes every frame; each daemon resize rebuilds the surface
/// from a replay, so reports are held until two frames pass unchanged.
final class ResizeCoordinator: NSObject {
    static let shared = ResizeCoordinator()

    private var settle = ResizeSettle<ObjectIdentifier, CellSize>(stableFrames: 3)
    private var targets: [ObjectIdentifier: DaemonTerminalIO] = [:]
    private var link: CADisplayLink?

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
        if link == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        guard let link else {
            flushAll()
            return
        }
        link.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        for (key, size) in settle.tick() {
            targets.removeValue(forKey: key)?.applySettled(size)
        }
        if settle.isIdle { link.isPaused = true }
    }

    private func flushAll() {
        while !settle.isIdle {
            for (key, size) in settle.tick() { targets.removeValue(forKey: key)?.applySettled(size) }
        }
    }
}
