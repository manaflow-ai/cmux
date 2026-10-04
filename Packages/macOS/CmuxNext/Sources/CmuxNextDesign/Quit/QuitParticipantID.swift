import Foundation

/// The one id format of the R96 quit hook: `file:<host id>:<canonical path>`.
/// The host id is "local" for this Mac, else the Cloud or remote host id (not
/// empty, no ':'); the path is absolute (starts with '/') and may contain ':'.
/// A participant id and its recovery draft id are the same string, so the
/// registry removes the right draft after a save or a Don't Save.
public nonisolated enum QuitParticipantID {
    public static let localHost = "local"
    static let scheme = "file:"

    /// `file:<host>:<path>`.
    public static func file(host: String = localHost, path: String) -> String {
        "\(scheme)\(host):\(path)"
    }

    /// The host id and the path of a valid id; nil for any other string.
    public static func parse(_ id: String) -> (host: String, path: String)? {
        guard id.hasPrefix(scheme) else { return nil }
        let rest = id.dropFirst(scheme.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let host = rest[..<colon]
        let path = rest[rest.index(after: colon)...]
        guard !host.isEmpty, path.hasPrefix("/") else { return nil }
        return (String(host), String(path))
    }

    public static func isValid(_ id: String) -> Bool {
        parse(id) != nil
    }

    /// A log-safe description of an id: its scheme (at most 16 characters),
    /// its length and why it is not valid. Never the host or the path.
    static func shape(_ id: String) -> String {
        let scheme = id.firstIndex(of: ":").map { String(id[..<$0].prefix(16)) } ?? "<none>"
        let reason: String
        if !id.hasPrefix(Self.scheme) {
            reason = "not file:"
        } else if !id.dropFirst(Self.scheme.count).contains(":") {
            reason = "no host"
        } else if id.dropFirst(Self.scheme.count).hasPrefix(":") {
            reason = "empty host"
        } else {
            reason = "path not absolute"
        }
        return "scheme \(scheme), \(id.count) characters, \(reason)"
    }
}
