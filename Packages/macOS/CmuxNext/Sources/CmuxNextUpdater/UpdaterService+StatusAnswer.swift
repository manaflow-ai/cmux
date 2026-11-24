public import Foundation

/// Update Status (`updates.status`; palette row and `cmux settings update-status`): one read of the
/// running build, the staged update and whether a relaunch would install it now. Nothing changes.
/// The control method `updates.status` stays the full updater dump; this answers the three facts a
/// person or an agent acts on, plus one line the palette shows as a toast.
extension UpdaterService {
    /// What a relaunch would do now (`relaunch` in the answer).
    nonisolated public enum RelaunchReadiness: String, Sendable, Equatable {
        /// Nothing is staged: a relaunch runs the same build.
        case nothingStaged = "nothing_staged"
        /// A staged update installs on Restart to Update, or by itself, now.
        case ready
        /// A staged update waits for the moment to clear (``UpdateRelaunchHoldState``).
        case held
        /// The update is installing and cmux is relaunching.
        case installing
    }

    /// The answer for the running updater.
    public func statusAnswer(now: Date = Date()) -> [String: UpdateAnswerField] {
        Self.statusFields(version: identity.shortVersion, build: identity.build, track: identity.track.rawValue,
                          phase: indicatorPhase, stagedVersion: stagedVersion, hold: relaunchHold,
                          unavailable: installUnavailableReason, now: now)
    }

    /// The answer's fields from the updater's facts (pure; the tests call it).
    nonisolated static func statusFields(version: String, build: String, track: String, phase: UpdateIndicatorPhase,
                                         stagedVersion: String?, hold: UpdateRelaunchHoldState?,
                                         unavailable: String?, now: Date) -> [String: UpdateAnswerField] {
        var fields = state(phase, pending: false)
        fields["pending"] = nil
        fields["current_version"] = .string(version)
        fields["current_build"] = .string(build)
        fields["track"] = .string(track)
        let staged: String?? = switch phase {
        case .ready(let shown): .some(shown ?? stagedVersion)
        case .installing where stagedVersion != nil: .some(stagedVersion)
        default: .none
        }
        fields["staged"] = .bool(staged != nil)
        if case .some(let name?) = staged { fields["staged_version"] = .string(name) }
        let relaunch: RelaunchReadiness = switch phase {
        case .installing: .installing
        case .ready: hold == nil ? .ready : .held
        default: .nothingStaged
        }
        fields["relaunch"] = .string(relaunch.rawValue)
        if relaunch == .held, let hold {
            fields["relaunch_hold"] = .string(hold.reason.rawValue)
            fields["relaunch_hold_seconds"] = .double(hold.age(at: now).rounded())
        }
        if let unavailable { fields["updates_unavailable"] = .string(unavailable) }
        let running = version.hasSuffix(build) ? version : "\(version) (\(build))"
        let line: String = switch relaunch {
        case .nothingStaged: UpdaterStrings.statusNothingStaged(running)
        case .ready: UpdaterStrings.statusReady(running, staged.flatMap { $0 } ?? "?")
        case .held: UpdaterStrings.statusHeld(running, staged.flatMap { $0 } ?? "?", hold?.reason.description ?? "")
        case .installing: UpdaterStrings.statusInstalling(running)
        }
        fields["line"] = .string(line)
        return fields
    }
}
