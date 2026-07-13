import Testing
@testable import CmuxVPSProvisioning

@Suite("VPSHostHealth")
struct VPSHostHealthTests {
    private let version = "0.99.0"

    private func facts(
        hasSystemd: Bool = true,
        binaryExists: Bool = true,
        unitFileExists: Bool = true,
        unitActiveState: String = "active",
        installedVersions: [String] = ["0.99.0"]
    ) -> VPSHostFacts {
        VPSHostFacts(
            homeDirectory: "/home/dev",
            uid: 1000,
            unameOS: "Linux",
            unameArch: "x86_64",
            goOS: "linux",
            goArch: "amd64",
            hasSystemd: hasSystemd,
            binaryExists: binaryExists,
            unitFileExists: unitFileExists,
            unitActiveState: unitActiveState,
            installedVersions: installedVersions
        )
    }

    private func report(version: String, sessions: Int, running: Bool = true) -> VPSRemoteDaemonStatusReport {
        VPSRemoteDaemonStatusReport(
            binaryVersion: version,
            slot: "vps",
            daemons: [
                .init(
                    versionDir: version,
                    running: running,
                    version: running ? version : nil,
                    pid: running ? 4242 : nil,
                    uptimeSeconds: running ? 120 : nil,
                    ptySessions: running ? sessions : nil
                ),
            ]
        )
    }

    @Test("ssh failure is unreachable")
    func unreachable() {
        let health = VPSHostHealth.evaluate(facts: nil, report: nil, desiredVersion: version)
        #expect(health.state == .unreachable)
    }

    @Test("nothing installed is not-provisioned")
    func notProvisioned() {
        let bare = facts(binaryExists: false, unitFileExists: false, installedVersions: [])
        let health = VPSHostHealth.evaluate(facts: bare, report: nil, desiredVersion: version)
        #expect(health.state == .notProvisioned)
    }

    @Test("active unit with matching daemon version is running")
    func running() {
        let health = VPSHostHealth.evaluate(
            facts: facts(),
            report: report(version: version, sessions: 3),
            desiredVersion: version
        )
        #expect(health.state == .running)
        #expect(health.liveSessions == 3)
        #expect(health.daemonVersion == version)
        #expect(health.uptimeSeconds == 120)
    }

    @Test("older running daemon needs upgrade")
    func needsUpgrade() {
        let health = VPSHostHealth.evaluate(
            facts: facts(),
            report: report(version: "0.98.0", sessions: 1),
            desiredVersion: version
        )
        #expect(health.state == .needsUpgrade)
        #expect(health.daemonVersion == "0.98.0")
    }

    @Test("installed but no daemon answering is stopped")
    func stopped() {
        let health = VPSHostHealth.evaluate(
            facts: facts(unitActiveState: "inactive"),
            report: report(version: version, sessions: 0, running: false),
            desiredVersion: version
        )
        #expect(health.state == .stopped)
    }

    @Test("daemon answering while unit is failed is degraded")
    func degradedUnit() {
        let health = VPSHostHealth.evaluate(
            facts: facts(unitActiveState: "failed"),
            report: report(version: version, sessions: 0),
            desiredVersion: version
        )
        #expect(health.state == .degraded)
    }

    @Test("running daemon without systemd is degraded")
    func degradedNoSystemd() {
        let health = VPSHostHealth.evaluate(
            facts: facts(hasSystemd: false, unitFileExists: false),
            report: report(version: version, sessions: 2),
            desiredVersion: version
        )
        #expect(health.state == .degraded)
        #expect(health.liveSessions == 2)
    }

    @Test("daemon-status JSON round-trips through the report parser")
    func reportParsing() throws {
        let json = """
        {
          "binary_version": "0.99.0",
          "slot": "vps",
          "root": "/home/dev/.cmux/daemon",
          "daemons": [
            {"version_dir": "0.99.0", "running": true, "socket": "/tmp/x.sock",
             "pid": 77, "version": "0.99.0", "started_at_unix": 1700000000,
             "uptime_seconds": 42, "pty_sessions": 2},
            {"version_dir": "0.98.0", "running": false, "socket": "/tmp/y.sock"}
          ]
        }
        """
        let report = try VPSRemoteDaemonStatusReport.parse(json: json)
        #expect(report.binaryVersion == "0.99.0")
        #expect(report.daemons.count == 2)
        #expect(report.totalLiveSessions == 2)
        #expect(report.runningDaemons.map(\.versionDir) == ["0.99.0"])
    }
}
