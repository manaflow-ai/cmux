import CmuxNextWakeups
import Foundation

/// One run of the bundled acpmux CLI against this app's daemon (its ``AcpmuxEnvironment``
/// variables), through ``AsyncProcess``: no thread waits, its output is drained as it comes, and a
/// run past ``deadline`` gets SIGTERM, then SIGKILL after ``killGrace``. It returns only once the
/// child is gone, so the update queue never moves on with a run still going.
nonisolated struct AcpmuxPeerUpdateCommand: Sendable {
    struct Result: Sendable, Equatable {
        /// The exit status; nil when it did not start, a signal ended it or the deadline did.
        var status: Int32?
        var output: String
        var errors: String
    }

    var executable: URL
    var environment: [String: String]
    /// A `host update` uploads a binary over ssh and waits for the new daemon: minutes, not hours.
    var deadline: Duration = .seconds(900)
    /// How long a run past its deadline has after SIGTERM before SIGKILL.
    var killGrace: Duration = .seconds(10)

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
        // `finish`: a timeout returns once the child exited (SIGKILL after the grace), never before.
        let request = ProcessRequest(executable, arguments, environment: environment, errorOutput: .separate,
                                     timeout: deadline, onCancel: .finish, killGrace: killGrace)
        do {
            let outcome = try await AsyncProcess().run(request)
            return Result(status: outcome.exited ? outcome.status : nil, output: outcome.text,
                          errors: String(decoding: outcome.errorOutput, as: UTF8.self))
        } catch ProcessFailure.timedOut {
            return Result(status: nil, output: "", errors: "acpmux ran past its \(deadline) deadline and was stopped")
        } catch {
            return Result(status: nil, output: "", errors: "acpmux did not start: \(error)")
        }
    }
}
