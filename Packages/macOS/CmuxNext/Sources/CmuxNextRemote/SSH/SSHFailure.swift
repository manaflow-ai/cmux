public import Foundation

/// Why an ssh run failed, from its exit status and stderr.
public enum SSHFailure: Error, Hashable, Sendable {
    case authFailed(String)
    case hostKeyUntrusted(String)
    case unreachable(String)
    case remoteFailed(String)

    public enum Kind: Sendable { case authFailed, hostKeyUntrusted, unreachable, remoteFailed }

    public var kind: Kind {
        switch self {
        case .authFailed: .authFailed
        case .hostKeyUntrusted: .hostKeyUntrusted
        case .unreachable: .unreachable
        case .remoteFailed: .remoteFailed
        }
    }

    public var message: String {
        switch self {
        case .authFailed(let text), .hostKeyUntrusted(let text), .unreachable(let text), .remoteFailed(let text): text
        }
    }

    public static func classify(status: Int32, stderr: String) -> SSHFailure? { nil }
}
