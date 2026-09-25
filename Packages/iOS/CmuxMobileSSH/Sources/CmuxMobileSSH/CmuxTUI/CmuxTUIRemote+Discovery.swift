import Foundation

/// A cmux-tui session socket found on a host (`cmux-tui-<uid>/<name>.sock`).
public struct CmuxTUISessionSocket: Sendable, Equatable {
    /// Session name (the socket's file name without `.sock`).
    public var name: String
    /// Absolute socket path on the host.
    public var path: String
}

extension CmuxTUIRemote {
    /// Lists the session sockets of the SSH user in every runtime directory
    /// a cmux-tui owner may have chosen (`spec/transports.md`, Unix Socket):
    /// `$XDG_RUNTIME_DIR`, the macOS per-user temporary directory (a
    /// Terminal-started owner uses it, while an SSH login usually has no
    /// `TMPDIR`), `$TMPDIR`, then `/tmp`. The first directory that holds a
    /// name wins, matching the server's own precedence. Hashed socket names
    /// (`cmux-tui-hashed-<uid>`) do not carry the session name and are
    /// skipped. A listed socket may be stale (its owner exited); connecting
    /// then fails.
    public func listSessionSockets(on connection: SSHConnection) async throws -> [CmuxTUISessionSocket] {
        let script = #"""
        u=$(id -u)
        for d in "${XDG_RUNTIME_DIR:-}" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" "${TMPDIR:-}" /tmp; do
          [ -n "$d" ] || continue
          d="${d%/}/cmux-tui-$u"
          [ -d "$d" ] || continue
          for s in "$d"/*.sock; do [ -S "$s" ] && printf '%s\n' "$s"; done
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

    /// Parses one socket path per line, keeping the first path per name.
    static func parseSessionSockets(_ output: String) -> [CmuxTUISessionSocket] {
        var seen: Set<String> = []
        var sockets: [CmuxTUISessionSocket] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let path = String(line)
            guard path.hasSuffix(".sock"), let slash = path.lastIndex(of: "/") else { continue }
            let name = String(path[path.index(after: slash)...].dropLast(".sock".count))
            guard (try? validate(session: name)) != nil, seen.insert(name).inserted else { continue }
            sockets.append(CmuxTUISessionSocket(name: name, path: path))
        }
        return sockets
    }

    /// Connects to an owner that is already running at `socket` through
    /// `cmux-tui relay --socket`. Unlike ``connect(on:session:clientName:handshakeTimeout:)``
    /// this never starts an owner, so listing a host's sessions cannot
    /// create one.
    public func connect(
        on connection: SSHConnection,
        socket: CmuxTUISessionSocket,
        clientName: String = "cmux-ios",
        handshakeTimeout: Duration = .seconds(10)
    ) async throws -> CmuxTUIControl {
        try Self.validate(session: socket.name)
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
}
