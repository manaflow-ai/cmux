import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// A Cloud machine as a ``DaemonUpdateTarget`` of the shared `DaemonUpdatePolicy`: the same
/// `cmux link machine update` as Update Machine (``CloudMachineUpdate``), with `--to-bundled
/// --if-older`, so a machine on an older build than the app's gets the app's own pinned build, and
/// one on a newer build is left alone (the CLI orders the two by their source commit time). The CLI keeps the
/// running binary, swaps `~/.cmux/bin/cmux-tui`, restarts only the daemon (terminals and chats keep
/// running) and rolls back when the new daemon does not serve. The VM's acpmux is that same binary.
/// A machine too old for that (`machine_update_unsupported`) gets the same build through the Cloud
/// API's exec instead (``CloudLegacyMachineUpdate``), with the same guarantees.
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
        /// `cmux link machine update --to-bundled --if-older` on the machine's daemon socket.
        var update: @Sendable () async throws -> CloudMoveCLI.Answer
        /// Runs after every update that ran: lets the machine's connection reach its new daemon.
        /// `restarted` (``mayHaveRestarted(_:)``): the daemon may have restarted, so a connection the
        /// app still holds may be to the old one.
        var reconnect: @Sendable (_ restarted: Bool) async -> Void
        /// The update of a machine too old to update in place to `build` (``CloudLegacyMachineUpdate``),
        /// run when ``update`` answers `machine_update_unsupported` naming the commit it judged
        /// older (`judged`), and only while the machine still runs it; nil when the machine has no
        /// way for it (no Cloud API exec, or no pinned build of `build` in this app).
        var legacy: @Sendable (_ build: DaemonBuildCommit, _ judged: String) async -> CloudMoveCLI.Answer? = { _, _ in nil }
    }

    let machineID: String
    let displayName: String
    let source: Source
    /// Both toggles of the automatic Cloud update (``CloudTunables/updatesCloudMachines``), read
    /// before every step; tests replace it instead of the shared store.
    var enabled: @Sendable () -> Bool = { CloudTunables.updatesCloudMachines }

    var id: String { Self.id(machineID) }
    var sshHost: String? { nil }

    /// The policy, ledger and board key of machine `machineID`.
    static func id(_ machineID: String) -> String { "cloud:\(machineID)" }

    /// The Rust target of every Cloud machine (images/cmux-vm: x86_64).
    static let cloudTarget = "x86_64-unknown-linux-gnu"

    /// The machine's build while its daemon is connected, also one that serves everything this app
    /// uses; nil while it is not, and while the toggles are off (``CloudTunables``). The policy
    /// then leaves the machine alone, also one it queued before.
    ///
    /// Never a move back: a Cloud daemon's build string carries no date, so the policy cannot tell
    /// an older build from a newer one (another app, a newer nightly, moved the machine forward).
    /// The CLI does (`--if-older`, by the source commit time the machine's daemon and this app's
    /// cmux-tui both report): a machine on a newer build answers `not_older` and is left alone
    /// (``DaemonUpdateOutcome/handledElsewhere``). Until 2026-10-27 a machine that served every
    /// capability this app uses was never updated automatically, so it stayed on its image's
    /// build after every app update (a VM on 8b3b1891 under an app on 52b77ef2f).
    func currentBuild() async -> String? {
        guard enabled(), let daemon = await source.daemon(), daemon.level != .incompatible,
              let build = daemon.build, !build.isEmpty else { return nil }
        return build
    }

    /// A machine whose daemon the app refused: its build is unknown (the handshake ended before
    /// the app read it) but surely not the app's, and nothing on it is in use through the app.
    var urgent: Bool {
        get async {
            guard enabled() else { return false }
            return await source.daemon()?.level == .incompatible
        }
    }

    func update(to build: DaemonBuildCommit, whileBusy: Bool) async -> DaemonUpdateOutcome {
        // Gone or not connected now: try again later. A toggle turned off since the policy read the
        // machine: no update starts; asked again, the machine reports no build and is dropped.
        guard enabled(), await source.daemon() != nil else { return .busy }
        var outcome: DaemonUpdateOutcome
        var answer: CloudMoveCLI.Answer?, pinned: String?
        do {
            var reply = try await source.update()
            // Too old to update in place: the Cloud API's exec installs the build instead, over the
            // build the CLI judged older only (none named: no build to hold it to, so not this way).
            if reply.errorCode == "machine_update_unsupported", let judged = reply.build, !judged.isEmpty,
               let legacy = await source.legacy(build, judged) { (reply, pinned) = (legacy, legacy.build) }
            answer = reply
            outcome = Self.outcome(reply, machine: displayName)
        } catch DaemonError.timedOut {
            // The CLI ran past its deadline: how the update ended is unknown, so ask again later
            // (the machine then reports its build) rather than record a failure for this build.
            outcome = .busy
        } catch {
            outcome = .failed(reason: String(describing: error))
        }
        // A DEV build's tree pin is its tree's publishing commit, which the machine then reports.
        if case .updated(let reported?) = outcome, !build.sameCommit(reported), reported != pinned {
            outcome = .failed(reason: "the machine reports build \(reported) after the update, not \(build.hash)")
        }
        await source.reconnect(Self.mayHaveRestarted(answer))
        return outcome
    }

    /// Whether the machine's daemon may have restarted in the run that gave `answer` (nil: the CLI
    /// gave none, a timeout or a kill): an update, a rollback, or an end the CLI lost track of. Not
    /// for a machine that needed nothing, nor for an answer given before anything reached it
    /// (another update runs, no daemon answer, no build to install, too old to update in place).
    static func mayHaveRestarted(_ answer: CloudMoveCLI.Answer?) -> Bool {
        guard let answer else { return true }
        if answer.ok { return answer.updated }
        switch answer.errorCode {
        case "machine_update_busy", "machine_unreachable", "machine_update_unavailable", "machine_update_download_failed",
             "machine_update_unsupported":
            return false
        default:
            return true
        }
    }

    /// The policy's outcome of one `link machine update` answer (cmux-tui `link/machine_update.rs`).
    static func outcome(_ answer: CloudMoveCLI.Answer, machine: String) -> DaemonUpdateOutcome {
        // A newer build than this app's (or the same tree): not this app's to replace, and not
        // "on this app's build" either. Not recorded, so the next launch asks again.
        if answer.ok, answer.notOlder { return .handledElsewhere }
        if answer.ok { return answer.updated ? .updated(build: answer.build) : .current }
        let detail = answer.error ?? answer.errorCode ?? CloudMoveCLI.badAnswer
        switch answer.errorCode {
        // Another update of the machine runs, or its daemon did not answer: not now, nothing changed.
        case "machine_update_busy", "machine_unreachable":
            return .busy
        // The CLI lost the machine before it read how the update ended: not recorded, so the
        // policy asks again (the CLI says to run it again), and the machine then reports its build.
        case "machine_update_unresolved":
            return .busy
        // This app carries no pinned machine build (a dev build), or its download failed: nothing
        // changed; not recorded, so a later connect or launch tries again.
        case "machine_update_unavailable", "machine_update_download_failed":
            return .needsBinary(target: cloudTarget)
        // Too old to update in place: no failure and no notice; not asked again while it runs
        // this build, whatever the app's build. Settings > Updates names it, with what still works.
        case "machine_update_unsupported":
            return .unsupported(reason: CloudMachineUpdateStrings.unsupported(machine))
        case "machine_update_rolled_back":
            return .rolledBack(reason: detail)
        default:
            return .failed(reason: detail)
        }
    }
}
