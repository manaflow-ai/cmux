internal import Foundation

/// Decoded output of the host-side `cmuxd-remote daemon-status --slot vps
/// --json` query: every persistent daemon for the slot across all installed
/// version directories, probed without spawning anything.
public struct VPSRemoteDaemonStatusReport: Equatable, Sendable, Codable {
    /// One per-version-directory daemon probe result.
    public struct Daemon: Equatable, Sendable, Codable {
        /// Version directory the slot lives under.
        public var versionDir: String
        /// True when a daemon answered on the slot socket.
        public var running: Bool
        /// Version the running daemon reported, if any.
        public var version: String?
        /// Daemon pid, if running.
        public var pid: Int?
        /// Seconds since the daemon started, if running.
        public var uptimeSeconds: Int?
        /// Live PTY session count, if running.
        public var ptySessions: Int?
        /// Unexpected probe error, if any.
        public var error: String?

        enum CodingKeys: String, CodingKey {
            case versionDir = "version_dir"
            case running
            case version
            case pid
            case uptimeSeconds = "uptime_seconds"
            case ptySessions = "pty_sessions"
            case error
        }

        /// Memberwise initializer (primarily for tests).
        public init(
            versionDir: String,
            running: Bool,
            version: String? = nil,
            pid: Int? = nil,
            uptimeSeconds: Int? = nil,
            ptySessions: Int? = nil,
            error: String? = nil
        ) {
            self.versionDir = versionDir
            self.running = running
            self.version = version
            self.pid = pid
            self.uptimeSeconds = uptimeSeconds
            self.ptySessions = ptySessions
            self.error = error
        }
    }

    /// Version of the binary that ran the query.
    public var binaryVersion: String
    /// Slot that was probed.
    public var slot: String
    /// Per-version daemon probe results.
    public var daemons: [Daemon]

    enum CodingKeys: String, CodingKey {
        case binaryVersion = "binary_version"
        case slot
        case daemons
    }

    /// Memberwise initializer (primarily for tests).
    public init(binaryVersion: String, slot: String, daemons: [Daemon]) {
        self.binaryVersion = binaryVersion
        self.slot = slot
        self.daemons = daemons
    }

    /// Total live PTY sessions across every running daemon for the slot.
    public var totalLiveSessions: Int {
        daemons.compactMap { $0.running ? $0.ptySessions : nil }.reduce(0, +)
    }

    /// The running daemon entries, newest version directory first.
    public var runningDaemons: [Daemon] {
        daemons.filter(\.running).sorted { $0.versionDir > $1.versionDir }
    }

    /// Decodes report JSON emitted by `cmuxd-remote daemon-status --json`.
    ///
    /// - Parameter json: Raw stdout of the query.
    /// - Returns: The decoded report.
    /// - Throws: ``VPSProvisioningError/probeParseFailed(detail:)`` on
    ///   malformed output.
    public static func parse(json: String) throws -> VPSRemoteDaemonStatusReport {
        guard let data = json.data(using: .utf8) else {
            throw VPSProvisioningError.probeParseFailed(detail: "daemon-status output is not UTF-8")
        }
        do {
            return try JSONDecoder().decode(VPSRemoteDaemonStatusReport.self, from: data)
        } catch {
            throw VPSProvisioningError.probeParseFailed(
                detail: "daemon-status output could not be decoded: \(error.localizedDescription)"
            )
        }
    }
}
