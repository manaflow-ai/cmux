import CmuxNextCompat
import CmuxNextWakeups
public import Foundation

/// One field of an update command's answer (`action.run` `result`).
nonisolated public enum UpdateAnswerField: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case double(Double)
}

/// What a waiting caller of Check for Updates or Install Available Update learns (the CLI,
/// claude-sr2 2026-10-26: "Fix the CLI commands so they install, or return a real error, never
/// "target -""): the answer's fields, a refusal (nothing to install, the policy forbids it) or a
/// failure.
nonisolated public enum UpdateCommandAnswer: Sendable, Equatable {
    case answered([String: UpdateAnswerField])
    case refused(String)
    case failed(String)
}

extension UpdaterService {
    /// How long an install's answer waits for the update to start installing before it answers
    /// with the state it reached (`pending`). Under the action run's settle limit (30 s).
    public static let installAnswerLimit: Duration = .seconds(20)

    /// The feed's answer for this Mac: the running and newest builds, or the check's failure.
    /// A managed policy that forbids updates refuses without touching the feed, as the check does.
    public func checkAnswer() -> Task<UpdateCommandAnswer, Never> {
        if case .managedPolicy? = disabledReason {
            let reason = UpdaterUnavailable(reason: .managedPolicy).description
            return Task { .refused(reason) }
        }
        let probe = probe()
        // task-owner: the action run; the capturing caller awaits it, and it ends with the probe.
        return Task { @MainActor [weak self] in
            if let failure = await probe.value { return .failed("update check failed: \(failure)") }
            guard let result = self?.lastProbe else { return .failed("update check failed: no result") }
            return .answered(Self.fields(result))
        }
    }

    nonisolated static func fields(_ result: UpdateProbeResult) -> [String: UpdateAnswerField] {
        var fields: [String: UpdateAnswerField] = [
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

    /// Follows the install a request started until it installs (the relaunch follows), ends with
    /// nothing to install or a failure (refused), or `limit` passes (the state it reached,
    /// `pending: true`, while it is still in progress). `baseline` is ``settledFlowMoves()`` taken
    /// before the request: a phase counts only once the gate moved after it, so an earlier check's
    /// note is not the answer, and a failure Sparkle reported inside the request is.
    public func installAnswer(after baseline: Int, limit: Duration = installAnswerLimit) -> Task<UpdateCommandAnswer, Never> {
        // task-owner: the action run; ends when the install settles, or when `timer` cancels it at `limit`.
        let follow = Task { @MainActor [weak self] () -> UpdateCommandAnswer? in
            for await seen in ObservationStream({ [weak self] in (self?.indicatorPhase ?? .hidden, self?.flowMoves ?? baseline) }) {
                if let settled = self?.installSettled(seen.0, moved: seen.1 != baseline) { return settled }
            }
            return nil
        }
        // Ends at `limit` (cancelling `follow`), or at once when `follow` settles first (its cancel below).
        let timer = DemandTimer(owner: "update-command-install-answer")
        timer.schedule(after: limit) { follow.cancel() }
        return Task { @MainActor [weak self] in
            let settled = await follow.value
            timer.cancel()
            if let settled { return settled }
            guard let self else { return .failed("the updater stopped") }
            // At the limit, only work in progress is pending. A note or the idle phase is final
            // even when the gate never moved (Sparkle failed the same way again inside the request).
            let phase = indicatorPhase
            return installSettled(phase, moved: true) ?? .answered(Self.state(phase, pending: true))
        }
    }

    /// The install's answer once `phase` settles it, else nil. `moved` says the gate moved after
    /// the request: before that, a note or the idle phase is what was already shown.
    func installSettled(_ phase: UpdateIndicatorPhase, moved: Bool) -> UpdateCommandAnswer? {
        switch phase {
        case .installing:
            return .answered(Self.state(phase, pending: false))
        case .note(let note) where moved:
            var reason = note.text
            if note == .checkFailed, let failure = failureReason { reason += ": \(failure)" }
            if note == .upToDate { reason += " (build \(identity.build))" }
            return .refused(reason)
        case .hidden where moved:
            return .refused("the update check ended without an update to install")
        case .hidden, .note, .checking, .downloading, .available, .ready:
            return nil
        }
    }

    nonisolated static func state(_ phase: UpdateIndicatorPhase, pending: Bool) -> [String: UpdateAnswerField] {
        var fields: [String: UpdateAnswerField] = ["pending": .bool(pending)]
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
