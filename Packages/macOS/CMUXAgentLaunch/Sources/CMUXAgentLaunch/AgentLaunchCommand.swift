import Foundation

/// A captured agent launch kept as structured values for later resume planning.
///
/// A capture either produced a trustworthy argv or it did not, and the record
/// says which: `arguments` carries the launch, or it is empty and
/// `rejectionReason` names the ground it was rejected on. The two never appear
/// together, on any path — `rejectionReason` is only reachable through
/// `init(rejectedOn:…)`, which fixes `arguments` to empty; decoding resolves the
/// one contradictory record cmux never writes in favour of the argv; and a later
/// mutation that gives a record a usable argv drops the ground with it.
public struct AgentLaunchCommand: Codable, Hashable, Sendable {
    /// The cmux launcher classification, when one was captured.
    public var launcher: String?
    /// The id of the user-declared external launcher that started the agent, when one was detected.
    ///
    /// This is deliberately separate from ``launcher``: that field is cmux's own classification and
    /// is matched against the agent kind (see ``AgentLaunchCaptureTrust``) and against the built-in
    /// wrapper tokens in ``AgentResumeArgv``, so an unknown value there would invalidate the whole
    /// capture. An external launcher only adds an argv prefix at resume time, resolved from
    /// `agents.launchers` in `cmux.json` (see ``AgentExternalLauncherRegistry``); a capture whose
    /// declaration was removed resumes exactly as it did before, without the wrapper.
    public var externalLauncher: String?
    /// The captured executable path.
    public var executablePath: String?
    /// The captured process arguments, including `argv[0]`. Empty on a capture
    /// that produced no trustworthy argv, where `rejectionReason` says why.
    ///
    /// Callers repair a usable launch in place (`replaySafeCodexLaunchCommand`
    /// rewrites `argv[0]`, `repairedCodexLaunchCommand` appends recovered
    /// permission flags), so a record can gain an argv after it was built. It
    /// drops the ground when it does: a launch a reader can replay is not a
    /// rejected capture, whatever it used to be.
    public var arguments: [String] {
        didSet {
            if !arguments.isEmpty {
                rejectionReason = nil
                if Self.isRejectedSourceMarker(source) {
                    source = nil
                }
            }
        }
    }
    /// The working directory at initial launch.
    public var workingDirectory: String?
    /// Replay-safe environment captured with the launch.
    public var environment: [String: String]?
    /// The launch user's home directory, retained only to resolve provider
    /// state during verification. It is not replayed as an environment override.
    public var verificationHome: String?
    /// The capture timestamp.
    public var capturedAt: TimeInterval?
    /// The capture source.
    public var source: String?
    /// Why this capture carries no trustworthy argv. Optional so records written
    /// before the field existed keep decoding, absent on a capture that produced
    /// a usable argv, and never set alongside one.
    public private(set) var rejectionReason: AgentLaunchCaptureRejectionReason?

    /// Whether this record explicitly rejects its launch capture as restore evidence.
    ///
    /// ``AgentLaunchCaptureRejectionReason/argvUnavailable`` describes an absent
    /// candidate and intentionally does not invalidate the historical environment
    /// or default fallback. PID-only mismatch and shell-wrapper grounds are also
    /// diagnostic fallback failures rather than positive launch-capture
    /// rejections. Explicit capture failures, sanitizer rejection, unknown
    /// grounds, and the legacy `source` verdict fail closed for resume and fork.
    public var isRejectedCapture: Bool {
        guard arguments.isEmpty else { return false }
        if let rejectionReason {
            return rejectionReason.isPositiveCaptureRejection
        }
        return Self.isRejectedSourceMarker(source)
    }

    /// A `source: "rejected"` marker beside a usable argv contradicts itself the
    /// same way a rejection ground would, so it is dropped with the ground.
    static func isRejectedSourceMarker(_ source: String?) -> Bool {
        source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "rejected"
    }

    /// Creates a structured captured launch.
    ///
    /// - Parameters:
    ///   - launcher: The cmux launcher classification, when one was captured.
    ///   - externalLauncher: The id of the user-declared external launcher that started the agent.
    ///   - executablePath: The captured executable path.
    ///   - arguments: The captured process arguments, including `argv[0]`.
    ///   - workingDirectory: The working directory at initial launch.
    ///   - environment: Replay-safe environment captured with the launch.
    ///   - verificationHome: The launch home used only for provider-state verification.
    ///   - capturedAt: The capture timestamp.
    ///   - source: The capture source.
    public init(
        launcher: String? = nil,
        externalLauncher: String? = nil,
        executablePath: String? = nil,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        verificationHome: String? = nil,
        capturedAt: TimeInterval? = nil,
        source: String? = nil
    ) {
        self.launcher = launcher
        self.externalLauncher = externalLauncher
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.verificationHome = verificationHome
        self.capturedAt = capturedAt
        self.source = !arguments.isEmpty && Self.isRejectedSourceMarker(source) ? nil : source
        self.rejectionReason = nil
    }

    /// Creates a capture that produced no trustworthy argv, naming the ground it
    /// was rejected on. `arguments` is empty by construction: this is the only
    /// way to set a rejection reason, so no producer can pair one with a launch
    /// that a reader could still replay.
    ///
    /// - Parameters:
    ///   - rejectionReason: The ground the captured argv was rejected on.
    ///   - launcher: The cmux launcher classification, when one was captured.
    ///   - externalLauncher: The id of the user-declared external launcher that started the agent.
    ///   - executablePath: The captured executable path, when one survived.
    ///   - workingDirectory: The working directory at initial launch.
    ///   - environment: Replay-safe environment captured with the launch.
    ///   - verificationHome: The launch home used only for provider-state verification.
    ///   - capturedAt: The capture timestamp.
    ///   - source: The capture source.
    public init(
        rejectedOn rejectionReason: AgentLaunchCaptureRejectionReason,
        launcher: String? = nil,
        externalLauncher: String? = nil,
        executablePath: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        verificationHome: String? = nil,
        capturedAt: TimeInterval? = nil,
        source: String? = nil
    ) {
        self.launcher = launcher
        self.externalLauncher = externalLauncher
        self.executablePath = executablePath
        self.arguments = []
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.verificationHome = verificationHome
        self.capturedAt = capturedAt
        self.source = source
        self.rejectionReason = rejectionReason
    }

    /// Decodes a stored record, keeping it as written except for the one
    /// combination cmux never writes.
    ///
    /// A record that carries both a usable argv and a rejection ground (or the
    /// legacy `source: "rejected"` marker) is
    /// self-contradictory: the argv is the actionable half, so the ground is
    /// dropped rather than surfaced through `sessions --json` next to a launch
    /// it does not describe. Every other record round-trips byte for byte,
    /// including a ground this build does not know — the store is rewritten in
    /// full on each mutation, so a token from a newer build has to survive an
    /// older one reading and writing it back.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launcher = try container.decodeIfPresent(String.self, forKey: .launcher)
        externalLauncher = try container.decodeIfPresent(String.self, forKey: .externalLauncher)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        // Required, as the synthesized decoder had it: a launch command without
        // an `arguments` key is a malformed record, not an empty capture.
        arguments = try container.decode([String].self, forKey: .arguments)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment)
        verificationHome = try container.decodeIfPresent(String.self, forKey: .verificationHome)
        capturedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .capturedAt)
        let storedSource = try container.decodeIfPresent(String.self, forKey: .source)
        source = !arguments.isEmpty && Self.isRejectedSourceMarker(storedSource) ? nil : storedSource
        let storedRejectionReason = try container.decodeIfPresent(
            AgentLaunchCaptureRejectionReason.self,
            forKey: .rejectionReason
        )
        rejectionReason = arguments.isEmpty ? storedRejectionReason : nil
    }
}

extension AgentLaunchCommand {
    /// Returns this record carrying an external launcher id recovered from other records.
    ///
    /// The external launcher is a property of the session, not of whichever capture won an evidence
    /// comparison. Ancestor detection can miss on a later hook — the launcher process may already be
    /// gone — so a record without an id must never erase the id the session was captured with.
    /// https://github.com/manaflow-ai/cmux/issues/10494
    ///
    /// - Parameter candidates: Other records for the same session, in preference order.
    /// - Returns: This record, with the first id found when it has none of its own.
    public func preservingExternalLauncher(from candidates: [AgentLaunchCommand?]) -> AgentLaunchCommand {
        if let own = Self.normalized(externalLauncher) {
            // Store the canonical form: the socket decoder accepts the id as written, so a padded
            // value would otherwise be persisted and compared with its padding intact.
            guard own != externalLauncher else { return self }
            var canonical = self
            canonical.externalLauncher = own
            return canonical
        }
        guard let recovered = candidates
            .lazy
            .compactMap({ Self.normalized($0?.externalLauncher) })
            .first else {
            return self
        }
        var updated = self
        updated.externalLauncher = recovered
        return updated
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
