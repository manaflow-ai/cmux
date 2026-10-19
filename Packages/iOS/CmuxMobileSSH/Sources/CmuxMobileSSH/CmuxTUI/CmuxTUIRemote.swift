import Foundation

/// Entry point for using cmux-tui on an SSH host as a persistence layer.
///
/// A headless cmux-tui owner holds the terminals; the phone connects through
/// `cmux-tui relay`, which copies the session's JSON-lines control socket over
/// an SSH exec channel. Terminals survive the phone disconnecting, the relay
/// exiting, and the owner restarting (terminal-host processes persist).
public actor CmuxTUIRemote {
    /// The install location `cmux-tui remote ssh` probes (docs/remote.md).
    public static let defaultBinaryPath = "~/.local/bin/cmux-tui"

    /// Remote path of the cmux-tui binary. A leading `~/` expands to `$HOME`.
    public nonisolated let binaryPath: String

    public init(binaryPath: String = CmuxTUIRemote.defaultBinaryPath) {
        self.binaryPath = binaryPath
    }

    /// Reports the host's OS/arch and the installed binary, if any.
    public func probe(on connection: SSHConnection) async throws -> CmuxTUIProbe {
        let script = """
        uname -s; uname -m
        B=\(binaryPath.remoteShellPath)
        printf '%s\\n' "$B"
        if [ -x "$B" ]; then "$B" remote-probe --json 2>/dev/null || "$B" --version 2>/dev/null || echo; else echo missing; fi
        """
        let result = try await connection.exec(script.bourneShellCommand)
        let lines = result.stdoutString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 4 else {
            throw CmuxTUIError.malformedResponse("probe: \(result.stdoutString)\(result.stderrString)")
        }
        let raw = lines[3...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return CmuxTUIProbe(
            os: lines[0],
            arch: lines[1],
            binaryPath: lines[2],
            installed: raw == "missing" ? nil : Self.parseInstalled(raw)
        )
    }

    /// Starts the session's headless owner if needed (`server ensure`), then
    /// opens a relay channel and completes the `identify` handshake.
    ///
    /// - Parameters:
    ///   - session: session name; one owner and socket per name. Use a
    ///     product-scoped name (e.g. `cmux-ios`) rather than `main`.
    ///   - clientName: label shown by `list-clients`.
    public func connect(
        on connection: SSHConnection,
        session: String,
        clientName: String = "cmux-ios",
        handshakeTimeout: Duration = .seconds(30)
    ) async throws -> CmuxTUIControl {
        try Self.validate(session: session)
        let script = """
        B=\(binaryPath.remoteShellPath); S=\(session.posixShellSingleQuoted)
        [ -x "$B" ] || { echo "cmux-tui not found at $B" >&2; exit 127; }
        "$B" server ensure --session "$S" --json >&2 || exit $?
        exec "$B" relay --session "$S"
        """
        let channel = try await connection.openSession(start: .exec(script.bourneShellCommand))
        return try await CmuxTUIControl.open(
            channel: channel,
            session: session,
            clientName: clientName,
            handshakeTimeout: handshakeTimeout
        )
    }

    /// Stops the session's owner (`server stop`). Terminal-host processes and
    /// durable topology survive; the next `connect` restores them.
    @discardableResult
    public func stopServer(on connection: SSHConnection, session: String) async throws -> SSHExecResult {
        try Self.validate(session: session)
        let script = "\(binaryPath.remoteShellPath) server stop --session \(session.posixShellSingleQuoted) --json"
        return try await connection.exec(script.bourneShellCommand)
    }

    /// Mirrors the server's session-name rule (single path component, no
    /// whitespace or control characters, at most 64 bytes).
    static func validate(session: String) throws {
        let invalid = session.isEmpty
            || session.utf8.count > 64
            || session == "." || session == ".."
            || session.contains("/") || session.contains("\\")
            || session.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control }
        if invalid { throw CmuxTUIError.invalidSessionName(session) }
    }

    static func parseInstalled(_ raw: String) -> CmuxTUIInstalledBinary {
        struct Probe: Decodable {
            var version: String?
            var distribution_version: String?
            var build_identity: String?
            var remote_protocol: Int?
        }
        if raw.hasPrefix("{"), let probe = try? JSONDecoder().decode(Probe.self, from: Data(raw.utf8)) {
            return CmuxTUIInstalledBinary(
                version: probe.version,
                distributionVersion: probe.distribution_version,
                buildIdentity: probe.build_identity,
                remoteProtocol: probe.remote_protocol,
                rawProbe: raw
            )
        }
        // `cmux 0.1.0 (<commit>; ghostty <commit>)`
        let words = raw.split(separator: " ")
        let version = words.count >= 2 ? String(words[1]) : nil
        return CmuxTUIInstalledBinary(version: version, distributionVersion: nil, buildIdentity: nil, remoteProtocol: nil, rawProbe: raw)
    }
}
