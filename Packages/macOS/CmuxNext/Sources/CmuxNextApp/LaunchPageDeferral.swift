import CmuxNextDesign
import CmuxNextWakeups

/// No page view (WebKit or Chromium) is made before the first window frame commits (startup-tti).
/// A warm relaunch made one for a restored chat, browser tab or page while the window was built:
/// its init ran inside `WindowController.init` (~25 ms) and laying it out ran engine setup inside
/// the first commit (~67 ms). The first frame needs only native views; a pane whose page waits
/// draws its last frame (`AgentTabContent.drawLastPage`) or its empty ground, and shows the page
/// once the frame committed, from `FirstFrameGate`.
///
/// Unbound (tests, a launch with no app delegate) it defers nothing.
@MainActor
final class LaunchPageDeferral {
    private var gate: FirstFrameGate?
    /// The pages waiting for the frame, by tab key, in the order they asked.
    private var waiting: [(key: String, show: @MainActor () -> Void)] = []

    /// Pages wait for `gate`'s first frame from now on.
    func bind(_ gate: FirstFrameGate) { self.gate = gate }

    /// True when `key`'s page must wait for the first frame: `show` runs once it committed (once per key).
    func defers(_ key: String, show: @escaping @MainActor () -> Void) -> Bool {
        guard let gate, !gate.isOpen else { return false }
        if waiting.contains(where: { $0.key == key }) { return true }
        if waiting.isEmpty {
            DebugTimings.markLaunch("pages.deferred_until_frame")
            gate.whenOpen { [weak self] in self?.showWaiting() }
        }
        waiting.append((key, show))
        return true
    }

    private func showWaiting() {
        let shows = waiting
        waiting.removeAll()
        for entry in shows { entry.show() }
        DebugTimings.markLaunch("pages.created")
    }
}
