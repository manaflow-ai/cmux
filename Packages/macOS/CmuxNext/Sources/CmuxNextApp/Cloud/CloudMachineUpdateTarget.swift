import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// A Cloud machine as a ``DaemonUpdateTarget`` of the shared `DaemonUpdatePolicy`: the same
/// `cmux link machine update` as Update Machine (``CloudMachineUpdate``), with `--to-bundled`, so a
/// machine on any other build than the app's gets the app's own pinned build. The CLI keeps the
/// running binary, swaps `~/.cmux/bin/cmux-tui`, restarts only the daemon (terminals and chats keep
/// running) and rolls back when the new daemon does not serve. The VM's acpmux is that same binary.
///
/// When: whenever the policy asks, with no wait for idle, also while an agent works there; the new
/// daemon adopts the terminals and chats that kept running and resumes what it interrupted (Leo:
/// "OUR SHIT IS HARDLY EVER GOING TO GO IDLE ... IT RESUMES WHATEVER IT INTERRUPTED"). So it has no
/// idle check of its own and `whileBusy` changes nothing; it answers `busy` only when the CLI
/// cannot update now. A machine whose daemon the app refused (`incompatible`) goes first: it cannot
/// connect, so nothing on it is in use through the app.
nonisolated struct CloudMachineUpdateTarget: DaemonUpdateTarget {
    /// The machine's daemon as the app last saw it.
    struct Daemon: Sendable, Equatable {
        /// Its `identify` build commit; nil when the handshake refused it before the app read it.
        var build: String?
        var level: DaemonCompatibility.Level
    }

    /// The machine's side, injected so the decisions run without a VM.
    struct Source: Sendable {
        /// The machine's daemon now; nil while it neither answered nor was refused.
        var daemon: @Sendable () async -> Daemon?
        /// `cmux link machine update --to-bundled` on the machine's daemon socket.
        var update: @Sendable () async throws -> CloudMoveCLI.Answer
        /// Runs after every update that ran: lets the machine's connection reach its new daemon.
        var reconnect: @Sendable () async -> Void
    }

    let machineID: String
    let displayName: String
    let source: Source

    var id: String { Self.id(machineID) }
    var sshHost: String? { nil }

    /// The policy, ledger and board key of machine `machineID`.
    static func id(_ machineID: String) -> String { "cloud:\(machineID)" }

    /// The Rust target of every Cloud machine (images/cmux-vm: x86_64).
    static let cloudTarget = "x86_64-unknown-linux-gnu"

    /// Nil while the toggles are off (``CloudTunables``): the policy then leaves the machine
    /// alone, also one it queued before the toggle went off.
    func currentBuild() async -> String? {
        guard CloudTunables.updatesCloudMachines, let build = await source.daemon()?.build, !build.isEmpty else { return nil }
        return build
    }

    /// A machine whose daemon the app refused: its build is unknown (the handshake ended before
    /// the app read it) but surely not the app's, and nothing on it is in use through the app.
    var urgent: Bool {
        get async {
            guard CloudTunables.updatesCloudMachines else { return false }
            return await source.daemon()?.level == .incompatible
        }
    }

    func update(to build: DaemonBuildCommit, whileBusy: Bool) async -> DaemonUpdateOutcome {
        // Gone or not connected now: try again later.
        guard await source.daemon() != nil else { return .busy }
        let outcome: DaemonUpdateOutcome
        do {
            outcome = Self.outcome(try await source.update(), machine: displayName)
        } catch {
            outcome = .failed(reason: String(describing: error))
        }
        await source.reconnect()
        return outcome
    }

    /// The policy's outcome of one `link machine update` answer (cmux-tui `link/machine_update.rs`).
    static func outcome(_ answer: CloudMoveCLI.Answer, machine: String) -> DaemonUpdateOutcome {
        if answer.ok { return answer.updated ? .updated(build: answer.build) : .current }
        let detail = answer.error ?? answer.errorCode ?? CloudMoveCLI.badAnswer
        switch answer.errorCode {
        // Another update of the machine runs, or its daemon did not answer: not now, nothing changed.
        case "machine_update_busy", "machine_unreachable":
            return .busy
        // This app carries no pinned machine build (a dev build), or its download failed: nothing
        // changed; not recorded, so a later connect or launch tries again.
        case "machine_update_unavailable", "machine_update_download_failed":
            return .needsBinary(target: cloudTarget)
        // Too old to update in place: final for this build, one notice.
        case "machine_update_unsupported":
            return .failed(reason: CloudMachineUpdateStrings.unsupported(machine))
        case "machine_update_rolled_back":
            return .rolledBack(reason: detail)
        default:
            return .failed(reason: detail)
        }
    }
}
