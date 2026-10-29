import AppKit
@testable import CmuxNextDesign

/// Shared host capability checks for tests that assert AppKit animation state.
/// Blacksmith can expose an online virtual display while WindowServer is not
/// advancing frames, so `NSScreen.screens` and `CGDisplayIsAsleep` are not
/// sufficient admission checks.
@MainActor
enum GUIAnimationTestSupport {
    /// Waits until `done()` holds: a fade ends on its completion, which the render server sends
    /// when the animation ran on screen, so a loaded host (a shared step host runs PR jobs
    /// beside the suite) sends it late, never early. A fixed sleep reads the state before that;
    /// this reads it after. `seconds` only bounds a fade that never ends (a real failure).
    static func settle(within seconds: Int = 10, until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !done() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// The animations are queued: a screen that is awake and speed not "off". Checks only what is
    /// queued, not that the display advances frames, so a Mac mini whose display does not still runs
    /// a test that reads only the queued animations or the commit order (`MotionCommitProbeTests`).
    static func queuesAnimations() async -> Bool {
        guard let screen = NSScreen.main else { return false }
        return Motion.speed != .off && !DisplaySleep.shared.isAsleep(screen)
    }

    static func animatesHere() async -> Bool {
        guard let screen = NSScreen.main, Motion.speed != .off,
              !DisplaySleep.shared.isAsleep(screen),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        let display = CGDirectDisplayID(number.uint32Value)
        guard CGDisplayIsOnline(display) != 0, CGDisplayIsActive(display) != 0,
              CGDisplayCopyDisplayMode(display) != nil else { return false }
        return await nextFrame(on: screen)
    }

    /// Waits for the next frame `screen`'s display link ticks; false when none came within 350 ms.
    static func nextFrame(on screen: NSScreen) async -> Bool {
        let probe = DisplayFrameProbe(screen: screen)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await probe.waitForFrame() }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(350))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            await MainActor.run { probe.stop() }
            return result
        }
    }

    @MainActor
    private final class DisplayFrameProbe: NSObject {
        private var link: CADisplayLink?
        private var continuation: CheckedContinuation<Bool, Never>?

        init(screen: NSScreen) {
            super.init()
            let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
            self.link = link
        }

        func waitForFrame() async -> Bool {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                // Install the continuation before starting the link; a fast display can
                // deliver its first tick synchronously on the next run-loop turn.
                link?.add(to: .main, forMode: .common)
            }
        }

        @objc private func frame(_: CADisplayLink) { finish(true) }

        func stop() {
            finish(false)
            link?.invalidate()
            link = nil
        }

        private func finish(_ result: Bool) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }
}
