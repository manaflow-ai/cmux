import CmuxNextActions
import CmuxNextCompat
import CmuxNextUpdater
import CmuxNextWakeups
import Foundation

/// What a CLI run of the update actions answers (`action.run` `result`), so
/// `cmux settings check-for-updates` and `install-available-update` say what
/// happened instead of only `ran` (claude-sr2 2026-10-26: "Fix the CLI commands
/// so they install, or return a real error, never "target -"").
extension UpdateHandlers {
    /// How long an install run waits for the update to start installing before it answers
    /// with the state it reached (`pending`). Under the action run's settle limit (30 s).
    static let installAnswerLimit: Duration = .seconds(20)

    /// The feed's answer for this Mac: the running and newest builds, or the check's failure.
    /// A managed policy that forbids updates refuses without touching the feed, as the check does.
    static func checkResult(_ updater: UpdaterService) -> ActionResultWork {
        if case .managedPolicy? = updater.disabledReason {
            let reason = UpdaterUnavailable(reason: .managedPolicy).description
            return Task { .failure(ActionWorkFailure(refusal: .unavailable, reason: reason)) }
        }
        let probe = updater.probe()
        // task-owner: the action run; the capturing caller awaits it, and it ends with the probe.
        return Task { @MainActor in
            if let failure = await probe.value { return .failure(ActionWorkFailure("update check failed: \(failure)")) }
            guard let result = updater.lastProbe else { return .failure(ActionWorkFailure("update check failed: no result")) }
            return .success(fields(result))
        }
    }

    static func fields(_ result: UpdateProbeResult) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = [
            "outcome": .string(result.outcome.kind),
            "current_build": .string(result.currentBuild),
            "feed": .string(result.feedURL),
        ]
        switch result.outcome {
        case .updateAvailable(let item), .requiresNewerSystem(let item, _), .upToDate(latest: let item?):
            fields["newest_build"] = .string(item.version)
            fields["newest_version"] = .string(item.displayVersion)
        case .upToDate(latest: nil):
            break
        }
        return fields
    }

    /// Follows the install the action started until it installs (the relaunch follows), ends
    /// with nothing to install or a failure (the run's error), or `limit` passes (the state it
    /// reached, `pending: true`, while it is still in progress). `baseline` is ``UpdaterService/flowMoves`` before the request:
    /// a phase counts only once the gate moved after it, so an earlier check's note is not the
    /// answer, and a failure Sparkle reported inside the request is.
    static func installResult(_ updater: UpdaterService, after baseline: Int, limit: Duration = installAnswerLimit) -> ActionResultWork {
        // task-owner: the action run; ends when the install settles, or when `timer` cancels it at `limit`.
        let follow = Task { @MainActor () -> Result<[String: ActionResultValue], ActionWorkFailure>? in
            for await seen in ObservationStream({ (updater.indicatorPhase, updater.flowMoves) }) {
                if let settled = installSettled(seen.0, moved: seen.1 != baseline, updater: updater) { return settled }
            }
            return nil
        }
        // Ends at `limit` (cancelling `follow`), or at once when `follow` settles first (its cancel below).
        let timer = DemandTimer(owner: "update-cli-install-answer")
        timer.schedule(after: limit) { follow.cancel() }
        return Task { @MainActor in
            let settled = await follow.value
            timer.cancel()
            if let settled { return settled }
            // At the limit, only work in progress is pending. A note or the idle phase is final
            // even when the gate never moved (Sparkle failed the same way again inside the request).
            let phase = updater.indicatorPhase
            return installSettled(phase, moved: true, updater: updater) ?? .success(state(phase, pending: true))
        }
    }

    /// The run's answer once `phase` settles it, else nil. `moved` says the gate moved after the
    /// request: before that, a note or the idle phase is what was already shown.
    static func installSettled(_ phase: UpdateIndicatorPhase, moved: Bool, updater: UpdaterService) -> Result<[String: ActionResultValue], ActionWorkFailure>? {
        switch phase {
        case .installing:
            return .success(state(phase, pending: false))
        case .note(let note) where moved:
            var reason = note.text
            if note == .checkFailed, let failure = updater.failureReason { reason += ": \(failure)" }
            if note == .upToDate { reason += " (build \(updater.identity.build))" }
            return .failure(ActionWorkFailure(refusal: .unavailable, reason: reason))
        case .hidden where moved:
            return .failure(ActionWorkFailure(refusal: .unavailable, reason: "the update check ended without an update to install"))
        case .hidden, .note, .checking, .downloading, .available, .ready:
            return nil
        }
    }

    static func state(_ phase: UpdateIndicatorPhase, pending: Bool) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = ["pending": .bool(pending)]
        switch phase {
        case .hidden: fields["state"] = .string("idle")
        case .checking: fields["state"] = .string("checking")
        case .downloading(let transfer):
            fields["state"] = .string("downloading")
            if let fraction = transfer.fraction { fields["progress"] = .double(fraction) }
        case .available(let version):
            fields["state"] = .string("available")
            if let version { fields["version"] = .string(version) }
        case .ready(let version):
            fields["state"] = .string("ready")
            if let version { fields["version"] = .string(version) }
        case .installing: fields["state"] = .string("installing")
        case .note(let note): fields["state"] = .string(note.text)
        }
        return fields
    }
}
