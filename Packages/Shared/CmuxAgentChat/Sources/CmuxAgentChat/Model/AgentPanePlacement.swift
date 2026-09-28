import Foundation

/// Where an agent pane's process runs.
public enum AgentPanePlacement: Sendable, Equatable {
    /// On this Mac.
    case local
    /// On a `cmux ssh` host, kept alive by its remote daemon.
    case ssh(host: String?)
    /// On a cmux Cloud machine.
    case cloud

    /// Whether the agent keeps running when this app quits or relaunches.
    /// A separate fact from resume safety; each consumer decides what it means.
    public var survivesAppRelaunch: Bool {
        self != .local
    }

    /// The wire name: `local`, `ssh` or `cloud`.
    public var kind: String {
        switch self {
        case .local: "local"
        case .ssh: "ssh"
        case .cloud: "cloud"
        }
    }

    public var host: String? {
        if case .ssh(let host) = self { return host }
        return nil
    }
}
