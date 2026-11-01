import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation

/// One run of the bundled acpmux CLI against this app's daemon (its ``AcpmuxEnvironment``
/// variables), through ``AsyncProcess``: no thread waits, its output is drained as it comes, and a
/// run past ``deadline`` gets SIGTERM, then SIGKILL after ``killGrace``. A stopped run returns once
/// the kernel says the child exited (``AcpmuxChildExit``), at most ``exitBound`` after the SIGKILL,
/// so the update queue never moves on with a run still going unless a child outlives even SIGKILL.
nonisolated struct AcpmuxPeerUpdateCommand: Sendable {
    struct Result: Sendable, Equatable {
        /// The exit status; nil when it did not start, a signal ended it or the deadline did.
        var status: Int32?
        var output: String
        var errors: String
        /// A signal ended it (not its deadline, not a failed launch): the run was cut short, such
        /// as by a restart of the local daemon it talks to.
        var interrupted = false
    }

    var executable: URL
    var environment: [String: String]
    /// A `host update` uploads a binary over ssh and waits for the new daemon: minutes, not hours.
    var deadline: Duration = .seconds(900)
    /// How long a run past its deadline has after SIGTERM before SIGKILL.
    var killGrace: Duration = .seconds(10)
    /// How long a stopped run waits for its child's exit after the SIGKILL.
    var exitBound: Duration = .seconds(10)

    /// `acpmux --json host update NAME --binary-dir DIR --keep-newer [--if-idle]`. `--keep-newer`
    /// always: under the host's update lock the CLI leaves a peer alone that runs a later day's build
    /// or one with local changes (its own self-update may have moved it after the app read its
    /// build). `--if-idle` unless `whileBusy`: the CLI then leaves a peer mid-turn alone and answers
    /// busy. Without it, the update restarts the peer's daemon mid-turn, and the new daemon resumes
    /// what it interrupted.
    static func updateArguments(peer: String, binaryDirectory: URL, whileBusy: Bool) -> [String] {
        let arguments = ["--json", "host", "update", peer, "--binary-dir", binaryDirectory.path, "--keep-newer"]
        return whileBusy ? arguments : arguments + ["--if-idle"]
    }

    func run(_ arguments: [String]) async -> Result {
        let exit = AcpmuxChildExit()
        defer { exit.disarm() }
        // `finish`: a timeout resolves at the child's exit or at the SIGKILL, so the exit is confirmed below.
        let request = ProcessRequest(executable, arguments, environment: environment, errorOutput: .separate,
                                     timeout: deadline, onCancel: .finish, killGrace: killGrace,
                                     onLaunch: { exit.arm($0) })
        do {
            let outcome = try await AsyncProcess().run(request)
            return Result(status: outcome.exited ? outcome.status : nil, output: outcome.text,
                          errors: String(decoding: outcome.errorOutput, as: UTF8.self), interrupted: !outcome.exited)
        } catch ProcessFailure.timedOut {
            let stopped = "acpmux ran past its \(deadline) deadline and was stopped"
            guard await exit.exited(within: exitBound) else {
                return Result(status: nil, output: "", errors: "\(stopped), but it still ran \(exitBound) after SIGKILL")
            }
            // Its exit is confirmed, by the SIGTERM or SIGKILL that stopped it: no status of its own to show.
            return Result(status: nil, output: "", errors: stopped)
        } catch {
            return Result(status: nil, output: "", errors: "acpmux did not start: \(error)")
        }
    }
}

/// The exit of one CLI child, from the kernel's exit event armed at its launch (while it surely
/// still runs; Foundation reaps the child, so its pid alone could not be waited on later).
///
/// Stop conditions: the exit source ends at the exit or at ``disarm()`` (the run's end, whichever
/// comes first); the deadline of ``exited(within:)`` at the exit or at its bound.
nonisolated final class AcpmuxChildExit: Sendable {
    private struct State {
        var exited = false
        var source: (any DispatchSourceProcess)?
        var waiter: CheckedContinuation<Bool, Never>?
    }

    // concurrency-allow: the exit flag, its source and the one waiter, shared by the launch callback, the exit event and the deadline (lock carve-out).
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.cmuxterm.next.acpmux-peer-update.exit")
    /// Ends a wait at its bound.
    private let deadline: DemandTimer

    init(clock: any Clock<Duration> = ContinuousClock()) {
        deadline = DemandTimer(owner: "acpmux-peer-update.exit", clock: clock)
    }

    /// Watches child `pid` for its exit: ``ProcessRequest/onLaunch``, right after the spawn.
    func arm(_ pid: Int32) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [self] in end(exited: true) }
        state.withLock { $0.source = source }
        source.resume()
        // Gone before the watch was on: no event comes.
        if kill(pid, 0) != 0, errno == ESRCH { end(exited: true) }
    }

    /// Ends the watch: the run is over.
    func disarm() {
        state.withLock { state in
            defer { state.source = nil }
            return state.source
        }?.cancel()
    }

    /// True once the child has exited; false when `bound` passes first.
    func exited(within bound: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let seen = state.withLock { state -> Bool in
                guard !state.exited else { return true }
                state.waiter = continuation
                return false
            }
            if seen { return continuation.resume(returning: true) }
            deadline.schedule(after: bound) { [self] in end(exited: false) }
        }
    }

    private func end(exited: Bool) {
        let (waiter, source) = state.withLock { state -> (CheckedContinuation<Bool, Never>?, (any DispatchSourceProcess)?) in
            defer {
                state.waiter = nil
                if exited { state.source = nil }
            }
            if exited { state.exited = true }
            return (state.waiter, exited ? state.source : nil)
        }
        source?.cancel()
        if exited { deadline.cancel() }
        waiter?.resume(returning: exited)
    }
}
