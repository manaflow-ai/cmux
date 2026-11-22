/// No page view (WebKit or Chromium) is made before the first window frame commits (startup-tti).
/// A warm relaunch made one for a restored chat, browser tab or page while the window was built:
/// its init ran inside `WindowController.init` (~25 ms) and laying it out ran engine setup inside
/// the first commit (~67 ms). The first frame needs only native views; a pane whose page waits
/// draws its last frame (the app's `AgentTabContent.drawLastPage`) or its empty ground, and shows the page
/// once the frame committed, from `FirstFrameGate`.
///
/// The app's is ``LaunchReveal/pages``. Unbound (tests, a launch with no app delegate) it defers nothing.
/// The predicate for which tab makes a page lives at its call sites (`PaneController.content(for:)`, `AgentTabContent`).
@MainActor
public final class LaunchPageDeferral {
    private var gate: FirstFrameGate?
    /// Writes a launch mark (the app's `DebugTimings.markLaunch`).
    private var mark: @MainActor (String) -> Void = { _ in }
    /// The pages waiting for the frame, by tab key, in the order they asked.
    private var waiting: [(key: String, show: @MainActor () -> Void)] = []

    public init() {}

    /// Pages wait for `gate`'s first frame from now on; `mark` gets `pages.deferred_until_frame` and `pages.created`.
    public func bind(_ gate: FirstFrameGate, mark: @escaping @MainActor (String) -> Void) { self.gate = gate; self.mark = mark }

    /// Pages wait now (the gate is bound and not open yet).
    public var holds: Bool { gate.map { !$0.isOpen } ?? false }

    /// True when `key`'s page must wait for the first frame: `show` runs once it committed (once per key).
    public func defers(_ key: String, show: @escaping @MainActor () -> Void) -> Bool {
        guard let gate, !gate.isOpen else { return false }
        if waiting.contains(where: { $0.key == key }) { return true }
        if waiting.isEmpty {
            mark("pages.deferred_until_frame")
            gate.whenOpen { [weak self] in self?.showWaiting() }
        }
        waiting.append((key, show))
        return true
    }

    private func showWaiting() {
        let shows = waiting
        waiting.removeAll()
        for entry in shows { entry.show() }
        mark("pages.created")
    }
}
