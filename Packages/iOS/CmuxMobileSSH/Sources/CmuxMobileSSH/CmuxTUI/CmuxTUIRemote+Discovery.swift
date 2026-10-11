import Crypto
import Foundation

/// A cmux-tui session socket found on a host: `cmux-tui-<uid>/<name>.sock`,
/// or `cmux-tui-hashed-<uid>/<sha256>.sock` for a session whose name is too
/// long for a Unix socket path (`spec/transports.md`, Path Resolution).
public struct CmuxTUISessionSocket: Sendable, Equatable {
    /// Session name (the socket's file name without `.sock`); `nil` for a
    /// hashed socket, whose owner reports its name in `identify`.
    public var name: String?
    /// Lowercase SHA-256 hex of the session name: the hashed socket's file
    /// name, or computed from ``name``.
    public var digest: String
    /// Absolute socket path on the host.
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.digest = Self.digest(of: name)
        self.path = path
    }

    public init(hashedDigest: String, path: String) {
        self.name = nil
        self.digest = hashedDigest
        self.path = path
    }

    /// Whether this socket belongs to `session`. A hashed socket is matched
    /// by digest, which is how the server derived its file name.
    public func serves(session: String) -> Bool {
        if let name { return name == session }
        return digest == Self.digest(of: session)
    }

    /// The full lowercase SHA-256 hex digest of the session's UTF-8 bytes.
    public static func digest(of session: String) -> String {
        SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ stem: String) -> Bool {
        stem.utf8.count == 64 && stem.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

extension CmuxTUIRemote {
    /// Lists the session sockets of the SSH user in every runtime directory
    /// a cmux-tui owner may have chosen (`spec/transports.md`, Unix Socket):
    /// `$XDG_RUNTIME_DIR`, the macOS per-user temporary directory (a
    /// Terminal-started owner uses it, while an SSH login usually has no
    /// `TMPDIR`), `$TMPDIR`, then `/tmp`. Each directory contributes its
    /// named sockets (`cmux-tui-<uid>`) and its hashed ones
    /// (`cmux-tui-hashed-<uid>`, very long session names). The first
    /// directory that holds a session wins, matching the server's own
    /// precedence. A listed socket may be stale (its owner exited);
    /// connecting then fails.
    public func listSessionSockets(on connection: SSHConnection) async throws -> [CmuxTUISessionSocket] {
        let script = #"""
        u=$(id -u)
        for d in "${XDG_RUNTIME_DIR:-}" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" "${TMPDIR:-}" /tmp; do
          [ -n "$d" ] || continue
          for k in "cmux-tui-$u" "cmux-tui-hashed-$u"; do
            s="${d%/}/$k"
            [ -d "$s" ] || continue
            for f in "$s"/*.sock; do [ -S "$f" ] && printf '%s\n' "$f"; done
          done
        done
        exit 0
        """#
        let result = try await connection.exec(script.bourneShellCommand)
        return Self.parseSessionSockets(result.stdoutString)
    }

    /// Finds an installed cmux-tui: the phone's install location
    /// (``defaultBinaryPath``) first, then one the user installed on `PATH`
    /// or in the usual Homebrew and `/usr/local` locations. `nil` when none
    /// is executable. Never installs anything.
    public static func locateBinary(on connection: SSHConnection) async -> String? {
        let script = #"""
        for p in "$HOME/.local/bin/cmux-tui" "$(command -v cmux-tui 2>/dev/null)" /opt/homebrew/bin/cmux-tui /usr/local/bin/cmux-tui; do
          [ -n "$p" ] && [ -x "$p" ] && [ ! -d "$p" ] && { printf '%s\n' "$p"; exit 0; }
        done
        exit 1
        """#
        guard let result = try? await connection.exec(script.bourneShellCommand), result.exitStatus == 0 else { return nil }
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Parses one socket path per line, keeping the first path per session.
    /// A file in a `cmux-tui-hashed-*` directory is a hashed socket (its
    /// name must be a SHA-256 hex digest); any other is a named socket whose
    /// name must be a valid session name.
    static func parseSessionSockets(_ output: String) -> [CmuxTUISessionSocket] {
        var seen: Set<String> = []
        var sockets: [CmuxTUISessionSocket] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let path = String(line)
            guard path.hasSuffix(".sock"), let slash = path.lastIndex(of: "/") else { continue }
            let stem = String(path[path.index(after: slash)...].dropLast(".sock".count))
            let directory = path[..<slash].split(separator: "/").last.map(String.init) ?? ""
            let socket: CmuxTUISessionSocket
            if directory.hasPrefix("cmux-tui-hashed-") {
                guard CmuxTUISessionSocket.isDigest(stem) else { continue }
                socket = CmuxTUISessionSocket(hashedDigest: stem, path: path)
            } else {
                guard (try? validateSocketSession(stem)) != nil else { continue }
                socket = CmuxTUISessionSocket(name: stem, path: path)
            }
            guard seen.insert(socket.digest).inserted else { continue }
            sockets.append(socket)
        }
        return sockets
    }

    /// Connects to an owner that is already running at `socket` through
    /// `cmux-tui relay --socket`. Unlike ``connect(on:session:clientName:handshakeTimeout:)``
    /// this never starts an owner, so listing a host's sessions cannot
    /// create one. The control's ``CmuxTUIControl/session`` is the name the
    /// owner reports, which is how a hashed socket learns its session.
    public func connect(
        on connection: SSHConnection,
        socket: CmuxTUISessionSocket,
        clientName: String = "cmux-ios",
        handshakeTimeout: Duration = .seconds(10)
    ) async throws -> CmuxTUIControl {
        if let name = socket.name { try Self.validateSocketSession(name) }
        let script = """
        B=\(binaryPath.remoteShellPath)
        [ -x "$B" ] || { echo "cmux-tui not found at $B" >&2; exit 127; }
        exec "$B" relay --socket \(socket.path.posixShellSingleQuoted)
        """
        let channel = try await connection.openSession(start: .exec(script.bourneShellCommand))
        return try await CmuxTUIControl.open(
            channel: channel,
            session: socket.name,
            clientName: clientName,
            handshakeTimeout: handshakeTimeout
        )
    }

    /// The server's own session-name rule (`validate_session_name`): a
    /// non-empty single path component without separators, NUL, control
    /// characters, or Unicode line separators. Spaces, Unicode, and long
    /// names are valid. `server ensure` is stricter (``validate(session:)``),
    /// but a session reached by its socket never passes through it.
    static func validateSocketSession(_ session: String) throws {
        let invalid = session.isEmpty
            || session == "." || session == ".."
            || session.unicodeScalars.contains { scalar in
                scalar == "/" || scalar == "\\" || scalar == "\0"
                    || scalar.properties.generalCategory == .control
                    || scalar == "\u{0085}" || scalar == "\u{2028}" || scalar == "\u{2029}"
            }
        if invalid { throw CmuxTUIError.invalidSessionName(session) }
    }
}
