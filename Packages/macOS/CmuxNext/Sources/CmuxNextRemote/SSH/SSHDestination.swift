public import Foundation

/// Where to reach a machine over SSH: what the user typed in "Connect to
/// Machine…" or `cmux remote connect`, as `[user@]host[:port]`,
/// `ssh://[user@]host[:port]` or `[user@][v6]:port`. The host may be an
/// alias from the user's `~/.ssh/config`; OpenSSH resolves it, cmux never
/// does. Nothing that could reach ssh as an option or a shell word passes.
public struct SSHDestination: Hashable, Sendable, CustomStringConvertible {
    public let user: String?
    public let host: String
    public let port: Int?

    public init(parsing text: String) throws(SSHDestinationError) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { throw .empty }
        guard !rest.hasPrefix("-") else { throw .optionLike }
        if rest.lowercased().hasPrefix("ssh://") {
            rest = String(rest.dropFirst("ssh://".count))
            if let slash = rest.firstIndex(of: "/") {
                guard rest[slash...] == "/" else { throw .path }
                rest = String(rest[..<slash])
            }
        }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            let name = String(rest[..<at])
            if name.contains(":") { throw .password }
            guard Self.isUser(name) else { throw .invalidUser }
            user = name
            rest = String(rest[rest.index(after: at)...])
        }
        var host = rest
        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw .invalidHost }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { throw .invalidHost }
                port = try Self.port(String(tail.dropFirst()))
            }
            guard host.contains(":"), host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { throw .invalidHost }
        } else {
            if let colon = rest.lastIndex(of: ":") {
                host = String(rest[..<colon])
                port = try Self.port(String(rest[rest.index(after: colon)...]))
            }
            guard Self.isHost(host) else { throw .invalidHost }
        }
        self.user = user
        self.host = host
        self.port = port
    }

    /// The destination argument for `ssh` (IPv6 bare, as OpenSSH wants it).
    public var sshArgument: String { user.map { "\($0)@\(host)" } ?? host }

    /// The `ssh://` route `cmux-tui remote connect` takes.
    public var route: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let userPart = user.map { "\($0)@" } ?? ""
        return "ssh://\(userPart)\(hostPart)" + (port.map { ":\($0)" } ?? "")
    }

    /// Canonical text form (what `init(parsing:)` reads back).
    public var description: String {
        let hostPart = host.contains(":") && port != nil ? "[\(host)]" : host
        return (user.map { "\($0)@" } ?? "") + hostPart + (port.map { ":\($0)" } ?? "")
    }

    /// Short name for the sidebar: the first label of a DNS name, else the
    /// host as given (an alias or an IP address).
    public var displayName: String {
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        return host.split(separator: ".").first.map(String.init) ?? host
    }

    private static func port(_ text: String) throws(SSHDestinationError) -> Int {
        guard let value = Int(text), (1...65535).contains(value) else { throw .invalidPort }
        return value
    }

    static func isUser(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.+-".unicodeScalars.contains($0)) }
    }

    static func isHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && !host.hasPrefix("-")
            && host.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }
}

public enum SSHDestinationError: Error, Equatable, Sendable {
    case empty
    /// Starts with `-`: ssh would read it as an option.
    case optionLike
    case invalidUser
    case invalidHost
    case invalidPort
    /// `user:password@host`: cmux never takes or stores passwords.
    case password
    /// `ssh://host/path`: a route has no path.
    case path
}

/// A cmux-tui session name on the remote machine (`--session`).
public struct RemoteSessionName {
    public init() {}
    public static let defaultName = "main"

    public struct Invalid: Error, Equatable, Sendable {
        public let name: String
    }

    /// `nil` or blank means `main`.
    public static func validate(_ name: String?) throws(Invalid) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultName }
        guard trimmed.count <= 64, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("."),
              trimmed.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) })
        else { throw Invalid(name: trimmed) }
        return trimmed
    }
}
