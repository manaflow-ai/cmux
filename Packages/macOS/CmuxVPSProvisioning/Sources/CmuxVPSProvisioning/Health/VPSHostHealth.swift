/// Health classification of a provisioned VPS host, derived from real daemon
/// signals (the unit's systemd state, a non-spawning daemon socket probe, and
/// the version the daemon itself reports) — never inferred from stale
/// client-side connection state.
public struct VPSHostHealth: Equatable, Sendable {
    /// Overall daemon state. Raw values appear in `--json` output; do not
    /// rename cases.
    public enum State: String, Equatable, Sendable {
        /// Supervised daemon is active and speaks the desired version.
        case running
        /// The daemon runs but something is off (unit inactive/failed while a
        /// daemon answers, no systemd supervision, or a probe inconsistency).
        case degraded
        /// A daemon is running an older version than the client expects.
        case needsUpgrade = "needs-upgrade"
        /// SSH reached the host but no daemon answered on the slot socket.
        case stopped
        /// The host did not answer over SSH.
        case unreachable
        /// The host has never been provisioned (no binary, no unit).
        case notProvisioned = "not-provisioned"
    }

    /// Overall state.
    public var state: State
    /// One-line detail suitable for CLI output.
    public var detail: String
    /// Version the newest running daemon reported, if any.
    public var daemonVersion: String?
    /// Live PTY sessions across running daemons for the slot.
    public var liveSessions: Int
    /// Seconds since the newest running daemon started, if any.
    public var uptimeSeconds: Int?

    /// Creates a health value.
    public init(
        state: State,
        detail: String,
        daemonVersion: String? = nil,
        liveSessions: Int = 0,
        uptimeSeconds: Int? = nil
    ) {
        self.state = state
        self.detail = detail
        self.daemonVersion = daemonVersion
        self.liveSessions = liveSessions
        self.uptimeSeconds = uptimeSeconds
    }

    /// Classifies host health from a probe and daemon report.
    ///
    /// - Parameters:
    ///   - facts: Probed host state (`nil` when SSH failed).
    ///   - report: Daemon socket probe results (`nil` when the query could
    ///     not run, for example no binary is installed yet).
    ///   - desiredVersion: The daemon version this client would install.
    /// - Returns: The classified health.
    public static func evaluate(
        facts: VPSHostFacts?,
        report: VPSRemoteDaemonStatusReport?,
        desiredVersion: String
    ) -> VPSHostHealth {
        guard let facts else {
            return VPSHostHealth(state: .unreachable, detail: "host did not answer over SSH")
        }

        let newestRunning = report?.runningDaemons.first
        let liveSessions = report?.totalLiveSessions ?? 0

        guard facts.binaryExists || !facts.installedVersions.isEmpty || facts.unitFileExists else {
            return VPSHostHealth(
                state: .notProvisioned,
                detail: "cmuxd-remote is not installed; run `cmux vps add`"
            )
        }

        guard let running = newestRunning else {
            let detail: String
            if facts.hasSystemd, facts.unitFileExists {
                detail = "unit is \(facts.unitActiveState.isEmpty ? "inactive" : facts.unitActiveState) and no daemon answered"
            } else if facts.hasSystemd {
                detail = "no supervised unit installed and no daemon answered"
            } else {
                detail = "no daemon answered (host has no systemd; daemon starts on demand)"
            }
            return VPSHostHealth(state: .stopped, detail: detail, liveSessions: liveSessions)
        }

        let runningVersion = running.version ?? running.versionDir
        if runningVersion != desiredVersion {
            return VPSHostHealth(
                state: .needsUpgrade,
                detail: "daemon runs \(runningVersion), client expects \(desiredVersion); run `cmux vps upgrade`",
                daemonVersion: runningVersion,
                liveSessions: liveSessions,
                uptimeSeconds: running.uptimeSeconds
            )
        }

        if !facts.hasSystemd {
            return VPSHostHealth(
                state: .degraded,
                detail: "daemon is running but unsupervised (host has no systemd)",
                daemonVersion: runningVersion,
                liveSessions: liveSessions,
                uptimeSeconds: running.uptimeSeconds
            )
        }
        if !facts.unitIsActive {
            return VPSHostHealth(
                state: .degraded,
                detail: "daemon answers but the systemd unit is \(facts.unitActiveState.isEmpty ? "inactive" : facts.unitActiveState)",
                daemonVersion: runningVersion,
                liveSessions: liveSessions,
                uptimeSeconds: running.uptimeSeconds
            )
        }

        return VPSHostHealth(
            state: .running,
            detail: "daemon \(runningVersion) supervised and healthy",
            daemonVersion: runningVersion,
            liveSessions: liveSessions,
            uptimeSeconds: running.uptimeSeconds
        )
    }
}
