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
public struct AgentLaunchCommand: Codable, Equatable, Sendable {
    /// The cmux launcher classification, when one was captured.
    public var launcher: String?
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

    /// Creates a structured captured launch.
    ///
    /// - Parameters:
    ///   - launcher: The cmux launcher classification, when one was captured.
    ///   - executablePath: The captured executable path.
    ///   - arguments: The captured process arguments, including `argv[0]`.
    ///   - workingDirectory: The working directory at initial launch.
    ///   - environment: Replay-safe environment captured with the launch.
    ///   - verificationHome: The launch home used only for provider-state verification.
    ///   - capturedAt: The capture timestamp.
    ///   - source: The capture source.
    public init(
        launcher: String? = nil,
        executablePath: String? = nil,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        verificationHome: String? = nil,
        capturedAt: TimeInterval? = nil,
        source: String? = nil
    ) {
        self.launcher = launcher
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.verificationHome = verificationHome
        self.capturedAt = capturedAt
        self.source = source
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
    ///   - executablePath: The captured executable path, when one survived.
    ///   - workingDirectory: The working directory at initial launch.
    ///   - environment: Replay-safe environment captured with the launch.
    ///   - verificationHome: The launch home used only for provider-state verification.
    ///   - capturedAt: The capture timestamp.
    ///   - source: The capture source.
    public init(
        rejectedOn rejectionReason: AgentLaunchCaptureRejectionReason,
        launcher: String? = nil,
        executablePath: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        verificationHome: String? = nil,
        capturedAt: TimeInterval? = nil,
        source: String? = nil
    ) {
        self.launcher = launcher
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
    /// A record that carries both a usable argv and a rejection ground is
    /// self-contradictory: the argv is the actionable half, so the ground is
    /// dropped rather than surfaced through `sessions --json` next to a launch
    /// it does not describe. Every other record round-trips byte for byte,
    /// including a ground this build does not know — the store is rewritten in
    /// full on each mutation, so a token from a newer build has to survive an
    /// older one reading and writing it back.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launcher = try container.decodeIfPresent(String.self, forKey: .launcher)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        // Required, as the synthesized decoder had it: a launch command without
        // an `arguments` key is a malformed record, not an empty capture.
        arguments = try container.decode([String].self, forKey: .arguments)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment)
        verificationHome = try container.decodeIfPresent(String.self, forKey: .verificationHome)
        capturedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .capturedAt)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        let storedRejectionReason = try container.decodeIfPresent(
            AgentLaunchCaptureRejectionReason.self,
            forKey: .rejectionReason
        )
        rejectionReason = arguments.isEmpty ? storedRejectionReason : nil
    }
}
