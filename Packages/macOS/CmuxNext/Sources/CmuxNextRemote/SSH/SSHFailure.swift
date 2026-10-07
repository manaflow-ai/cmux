public import Foundation

/// Why an ssh run failed, from its exit status and stderr. OpenSSH exits 255
/// for its own errors and prints them on stderr; the remote command's
/// status passes through otherwise. The message is the line the user needs
/// (OpenSSH's own wording), never a guess.
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

    public static func classify(status: Int32, stderr: String) -> SSHFailure? {
        guard status != 0 else { return nil }
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func line(_ needles: [String]) -> String? {
            lines.first { line in needles.contains { line.localizedCaseInsensitiveContains($0) } }
        }
        if line(hostKeyNeedles) != nil {
            return .hostKeyUntrusted(line(["Host key verification failed", "IDENTIFICATION HAS CHANGED"]) ?? lines.last ?? "")
        }
        if let denied = line(authNeedles) { return .authFailed(denied) }
        if let network = line(networkNeedles) { return .unreachable(network) }
        return .remoteFailed(lines.last ?? "ssh exited \(status)")
    }

    static let hostKeyNeedles = ["Host key verification failed", "REMOTE HOST IDENTIFICATION HAS CHANGED", "host key is known for",
                                 "No matching host key type", "Host key for", "has changed and you have requested strict checking"]
    static let authNeedles = ["Permission denied", "Too many authentication failures", "Authentication failed",
                              "no mutual signature algorithm", "sign_and_send_pubkey"]
    static let networkNeedles = ["Could not resolve hostname", "Connection refused", "timed out", "No route to host",
                                 "Network is unreachable", "Connection closed by", "Connection reset", "kex_exchange_identification",
                                 "Host is down", "Name or service not known", "Temporary failure in name resolution",
                                 "Broken pipe"]
}
