import CryptoKit
public import Foundation

/// One saved SSH machine: where it is, which cmux-tui session to attach,
/// and where cmux-tui lives on it. Stored as the session registry's
/// `transport` (plans/cmux-next/data-model.md 1.1): routing only, never a
/// password, key or token (authentication is the user's OpenSSH).
public struct SSHHost: Hashable, Sendable {
    public static let defaultRemoteBinary = "~/.local/bin/cmux-tui"
    public static let transportKind = "ssh"

    public let destination: SSHDestination
    public let session: String
    /// The cmux-tui on the machine, in the user's home by default (the
    /// same place `cmux-tui remote ssh` uses). A `~/` prefix expands there.
    public let remoteBinary: String
    /// A non-default cmux-tui state directory on the machine.
    public let remoteStateDir: String?
    /// An existing daemon socket on the machine to attach to instead of the
    /// session's own (a paired server's Chief brain); cmux-tui never starts
    /// a daemon there (`remote connect --remote-mux-socket`).
    public let remoteMuxSocket: String?

    public struct Invalid: Error, Equatable, Sendable {
        public let field: String
    }

    public init(destination: SSHDestination, session: String = RemoteSessionName.defaultName,
                remoteBinary: String = SSHHost.defaultRemoteBinary, remoteStateDir: String? = nil,
                remoteMuxSocket: String? = nil) throws(Invalid) {
        guard let name = try? RemoteSessionName.validate(session) else { throw Invalid(field: "session") }
        guard RemotePath.isSafe(remoteBinary) else { throw Invalid(field: "remote_binary") }
        if let remoteStateDir, !RemotePath.isSafe(remoteStateDir) { throw Invalid(field: "remote_state_dir") }
        if let remoteMuxSocket, !RemotePath.isSafe(remoteMuxSocket) { throw Invalid(field: "remote_mux_socket") }
        self.destination = destination
        self.session = name
        self.remoteBinary = remoteBinary
        self.remoteStateDir = remoteStateDir
        self.remoteMuxSocket = remoteMuxSocket
    }

    /// Stable id of this machine in the app (`MachineRegistry`), distinct per
    /// route, session and state directory, never `local` or a Cloud `vm-…` id.
    public var machineID: String {
        let key = ([destination.route, session, remoteStateDir ?? ""] + (remoteMuxSocket.map { [$0] } ?? [])).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "ssh-" + digest
    }

    /// Sidebar name: the host, plus the session when it is not `main`.
    public var label: String {
        session == RemoteSessionName.defaultName ? destination.displayName : "\(destination.displayName)/\(session)"
    }

    /// The registry `transport` object.
    public var transportFields: [String: String] {
        var fields = ["kind": Self.transportKind, "destination": destination.description, "session": session,
                      "remote_binary": remoteBinary]
        if let remoteStateDir { fields["remote_state_dir"] = remoteStateDir }
        if let remoteMuxSocket { fields["remote_mux_socket"] = remoteMuxSocket }
        return fields
    }

    /// Reads a registry `transport` object; nil for other kinds or anything
    /// that does not validate.
    public init?(transportFields fields: [String: String]) {
        guard fields["kind"] == Self.transportKind, let text = fields["destination"],
              let destination = try? SSHDestination(parsing: text),
              let host = try? SSHHost(destination: destination, session: fields["session"] ?? RemoteSessionName.defaultName,
                                      remoteBinary: fields["remote_binary"] ?? Self.defaultRemoteBinary,
                                      remoteStateDir: fields["remote_state_dir"], remoteMuxSocket: fields["remote_mux_socket"])
        else { return nil }
        self = host
    }
}

/// Paths on the remote machine as they appear in a remote shell command.
public struct RemotePath {
    public init() {}
    /// Plain path characters and a leading `~/`; no spaces, quotes or `$`.
    /// cmux-tui passes these into the remote command unquoted, so they must
    /// be plain words.
    public static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && path.count <= 512 && !path.hasPrefix("-")
            && path.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "/._~+-".unicodeScalars.contains($0)) }
    }

    /// A POSIX shell word for `path`: `~/rest` becomes `"$HOME"/'rest'` so
    /// the home still expands, everything else is single-quoted.
    public static func shellWord(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + quote(String(path.dropFirst(2))) }
        return quote(path)
    }

    /// Single-quotes `text` for a POSIX shell.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
