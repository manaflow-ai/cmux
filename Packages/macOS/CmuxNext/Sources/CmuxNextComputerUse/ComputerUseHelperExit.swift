import Darwin
import Dispatch

/// The kernel's exit event for one helper process (a process source, never a
/// poll). A helper can end without this app asking: macOS offers "Quit &
/// Reopen" after the person adds it in Screen & System Audio Recording and
/// only quits it, and a crash or a kill ends it too. `onExit` runs once, on
/// the main actor, unless `cancel()` comes first.
@MainActor
final class ComputerUseHelperExitWatch {
    private var source: (any DispatchSourceProcess)?
    private var onExit: (@MainActor () -> Void)?

    init(pid: pid_t, onExit: @escaping @MainActor () -> Void) {
        self.onExit = onExit
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        weak let weakSelf = self
        source.setEventHandler {
            // task-owner: one hop to the main actor per exit event.
            Task { @MainActor in weakSelf?.exited() }
        }
        self.source = source
        source.resume()
        // An exit before the source was armed raises no event.
        if kill(pid, 0) != 0, errno == ESRCH {
            // task-owner: one hop, so `onExit` never runs inside the caller's watch call.
            Task { @MainActor in weakSelf?.exited() }
        }
    }

    /// The launchers' watch: the returned closure cancels it.
    static func watch(_ pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let watch = ComputerUseHelperExitWatch(pid: pid, onExit: onExit)
        return { watch.cancel() }
    }

    func cancel() {
        onExit = nil
        source?.cancel()
        source = nil
    }

    private func exited() {
        let onExit = onExit
        cancel()
        onExit?()
    }
}

/// A helper's exit watch and its restart budget. After an exit this app did
/// not cause, the helper starts again at most `limit` times within `window`
/// (on the injected clock); past that it stays down until the person
/// restarts it or turns Computer Use off and on. A stop this app makes ends
/// the watch, so its own exit event is never taken for a crash.
@MainActor
final class ComputerUseHelperRestarts {
    static let limit = 3
    static let window: Duration = .seconds(60)
    private var cancelWatch: (@MainActor () -> Void)?
    /// Time on the injected clock since this budget was made.
    private let elapsed: () -> Duration
    private var recent: [Duration] = []

    init(clock: any Clock<Duration>) {
        elapsed = Self.stopwatch(clock)
    }

    /// The helper that runs now, by its watch's cancel.
    func watch(_ cancel: @escaping @MainActor () -> Void) {
        cancelWatch?()
        cancelWatch = cancel
    }

    /// A stop, restart or quit this app made: no exit event counts, and the
    /// next exit gets a fresh budget.
    func stopped() {
        cancelWatch?()
        cancelWatch = nil
        recent.removeAll()
    }

    /// The watched helper exited by itself: takes one restart, or false once
    /// `limit` restarts ran within `window`.
    func takeRestart() -> Bool {
        // The watch has fired, or its event never came (``ComputerUseHelperDaemon/confirmRunning()``): end it.
        cancelWatch?()
        cancelWatch = nil
        let now = elapsed()
        recent.removeAll { now - $0 >= Self.window }
        guard recent.count < Self.limit else { return false }
        recent.append(now)
        return true
    }

    private static func stopwatch(_ clock: some Clock<Duration>) -> () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }
}
