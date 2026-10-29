public import CmuxNextWakeups
public import Observation

/// The restored windows behind the front one that wait to be built, as
/// ``LaunchWindowVisibility`` split them: each window that shows is built in its own afterFirstFrame
/// post of the launch's ``StartupScheduler`` (one window per post, front first, so no main turn
/// builds them all), and each hidden one in its own afterStartup post. A window something acts in
/// before its post is taken out (``take(_:)``) and built by the caller at once, as Chrome loads a
/// restored tab the moment it is activated, ahead of its `TabLoader` turn
/// (chrome/browser/sessions/tab_loader.cc).
///
/// ``waitingVisible`` is observable: the launch's visible-pane refs count each window that shows
/// and is not built yet as one loading pane, so startup does not complete before it is built.
///
/// ```swift
/// let queue = LaunchWindowQueue(startup: startup) { id in manager.buildWaitingWindow(id) }
/// queue.schedule(visibility.split(saved, built: [front]))
/// if queue.take(id) { manager.build(id) } // something acts in it before its post
/// ```
@MainActor @Observable
public final class LaunchWindowQueue {
    /// Windows that show and wait for their afterFirstFrame post, front first.
    public private(set) var waitingVisible: [String] = []
    /// Hidden windows waiting for their afterStartup post, front first.
    @ObservationIgnored public private(set) var waitingHidden: [String] = []
    @ObservationIgnored private let startup: StartupScheduler
    @ObservationIgnored private let build: @MainActor (String) -> Void

    /// - Parameters:
    ///   - startup: The launch's scheduler.
    ///   - build: Builds one window; called once per window, from its post, never for a taken or dropped one.
    public init(startup: StartupScheduler, build: @escaping @MainActor (String) -> Void) {
        self.startup = startup
        self.build = build
    }

    /// Posts one build per window of `split`.
    ///
    /// - Parameter split: The windows that show and the hidden ones.
    /// - Returns: False once quit began: nothing waits and the caller builds them now.
    @discardableResult
    public func schedule(_ split: LaunchWindowVisibility.Split) -> Bool {
        if startup.log.phase == .quitting { return false }
        for id in split.visible where !isWaiting(id) {
            waitingVisible.append(id)
            startup.post(.afterFirstFrame, "WindowManager.buildVisibleWindow", on: .main) { [weak self] in self?.buildNextVisible() }
        }
        for id in split.hidden where !isWaiting(id) {
            waitingHidden.append(id)
            startup.post(.afterStartup, "WindowManager.buildHiddenWindow", on: .main) { [weak self] in self?.buildNextHidden() }
        }
        return true
    }

    /// Whether window `id` waits for its post.
    public func isWaiting(_ id: String) -> Bool {
        waitingVisible.contains(id) || waitingHidden.contains(id)
    }

    /// Takes window `id` out of the queue: the caller builds it now.
    ///
    /// - Returns: True when it waited.
    public func take(_ id: String) -> Bool {
        if let index = waitingVisible.firstIndex(of: id) {
            waitingVisible.remove(at: index)
            return true
        }
        guard let index = waitingHidden.firstIndex(of: id) else { return false }
        waitingHidden.remove(at: index)
        return true
    }

    /// Drops the waiting windows not in `open` (closed before their post): they are never built.
    public func keep(_ open: Set<String>) {
        if waitingVisible.contains(where: { !open.contains($0) }) { waitingVisible.removeAll { !open.contains($0) } }
        waitingHidden.removeAll { !open.contains($0) }
    }

    /// One post's window: the frontmost one still waiting (a taken or dropped window leaves a post with nothing to do).
    private func buildNextVisible() {
        guard !waitingVisible.isEmpty else { return }
        build(waitingVisible.removeFirst())
    }

    private func buildNextHidden() {
        guard !waitingHidden.isEmpty else { return }
        build(waitingHidden.removeFirst())
    }
}
