import Foundation

/// One step of `cmux-tui acp host enroll|doctor --json`, one JSON line each
/// (cmux-tui/crates/acpmux/src/cli/host_steps.rs, plans/cmux-next/add-machine-DESIGN.md):
/// `{"step","state","detail","fix"}`. The final line is `{"report":{...}}`.
public nonisolated struct HostStep: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let reach = HostStep(rawValue: "reach")
    public static let install = HostStep(rawValue: "install")
    public static let daemon = HostStep(rawValue: "daemon")
    public static let harness = HostStep(rawValue: "harness")
    public static let peer = HostStep(rawValue: "peer")
    public static let peerBack = HostStep(rawValue: "peer-back")
    public static let identity = HostStep(rawValue: "identity")

    /// The steps in the order they run. A newer cmux-tui may send others; they show by their raw name.
    public static let known: [HostStep] = [.reach, .install, .daemon, .harness, .peer, .peerBack, .identity]
}

public nonisolated enum HostStepState: String, Equatable, Sendable, Codable {
    /// The check passed with nothing to do.
    case ok
    /// The check failed and enroll (or `--fix`) repaired it.
    case fixed
    /// The check failed; `fix` says what a person can do.
    case fail
    /// Works from this side but not fully (a host that cannot ssh back).
    case warn
    /// Not run: an earlier step it depends on failed, or it was not asked for.
    case skip

    /// A state this build does not know reads as a warning: shown, never a pass.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = HostStepState(rawValue: text) ?? .warn
    }

    /// Whether the machine still counts as healthy after a step in this state.
    public var isHealthy: Bool { self != .fail }
}

/// One finished step.
public nonisolated struct HostStepResult: Equatable, Sendable, Codable {
    public var step: HostStep
    public var state: HostStepState
    public var detail: String
    /// A sentence for a person; never a command cmux runs for them.
    public var fix: String?
    /// Why it failed, for a failure the app acts on (acpmux `host_steps.rs`):
    /// `wrong-platform`, `peer_version_skew`, or `not-this-program` (the host
    /// needs a binary only the app has).
    public var reason: String?

    public static let wrongPlatform = "wrong-platform"
    /// The peer's build is stale and its platform is known to differ; the
    /// app should install the target-aware binary for that platform.
    public static let peerVersionSkew = "peer_version_skew"
    public static let notThisProgram = "not-this-program"

    public init(step: HostStep, state: HostStepState, detail: String = "", fix: String? = nil, reason: String? = nil) {
        self.step = step
        self.state = state
        self.detail = detail
        self.fix = fix
        self.reason = reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        step = try container.decode(HostStep.self, forKey: .step)
        state = try container.decode(HostStepState.self, forKey: .state)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        fix = try container.decodeIfPresent(String.self, forKey: .fix).flatMap { $0.isEmpty ? nil : $0 }
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// The last line of an enroll or doctor run.
public nonisolated struct HostReport: Equatable, Sendable, Codable {
    public var name: String
    public var host: String
    public var ok: Bool
    public var steps: [HostStepResult]

    public init(name: String, host: String, ok: Bool, steps: [HostStepResult]) {
        self.name = name
        self.host = host
        self.ok = ok
        self.steps = steps
    }

    /// The first failed step, else the first warning: what the Machines row's dot names.
    public var worstStep: HostStepResult? {
        steps.first { $0.state == .fail } ?? steps.first { $0.state == .warn }
    }

    public var health: HostHealth {
        if !ok || steps.contains(where: { $0.state == .fail }) { return .failing }
        return steps.contains { $0.state == .warn } ? .warning : .ok
    }
}

/// How a machine came out of its last enroll or doctor run.
public nonisolated enum HostHealth: Hashable, Sendable {
    case ok
    case warning
    case failing
}

/// One line of the CLI's output.
public nonisolated enum HostLine: Equatable, Sendable {
    case step(HostStepResult)
    case report(HostReport)

    /// Reads one stdout line; nil for a blank line or anything that is not a step or a report
    /// (a log line, a future line type).
    public static func parse(_ line: String) -> HostLine? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{") else { return nil }
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(ReportLine.self, from: data) { return .report(wrapped.report) }
        if let step = try? decoder.decode(HostStepResult.self, from: data) { return .step(step) }
        return nil
    }

    private nonisolated struct ReportLine: Decodable {
        let report: HostReport
    }
}
