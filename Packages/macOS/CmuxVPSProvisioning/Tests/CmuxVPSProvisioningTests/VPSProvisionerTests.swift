import Foundation
import Testing
@testable import CmuxVPSProvisioning

/// Scripted fake runner: matches each invocation against ordered rules and
/// records the commands it saw.
private actor FakeCommandRunner: VPSCommandRunning {
    struct Rule {
        let match: @Sendable (String, [String]) -> Bool
        let result: VPSCommandResult
    }

    private(set) var invocations: [(executable: String, arguments: [String])] = []
    private var rules: [Rule]
    private let fallback: VPSCommandResult

    init(rules: [Rule], fallback: VPSCommandResult = VPSCommandResult(status: 0, stdout: "", stderr: "")) {
        self.rules = rules
        self.fallback = fallback
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> VPSCommandResult {
        invocations.append((executable, arguments))
        for rule in rules where rule.match(executable, arguments) {
            return rule.result
        }
        return fallback
    }

    func commandLines() -> [String] {
        invocations.map { ([$0.executable] + $0.arguments).joined(separator: " ") }
    }
}

private struct FakeArtifacts: VPSDaemonArtifactProviding {
    var version: String = "0.99.0"
    var sha256: String = "aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899"
    var binaryURL = URL(fileURLWithPath: "/tmp/fake-cmuxd-remote")

    func expectedSHA256(goOS: String, goArch: String) -> String? { sha256 }

    func materialize(goOS: String, goArch: String) async throws -> VPSDaemonArtifact {
        VPSDaemonArtifact(localURL: binaryURL, sha256: sha256, version: version)
    }
}

@Suite("VPSProvisioner orchestration")
struct VPSProvisionerTests {
    private let helloOK = #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"0.99.0","capabilities":[]}}"#

    private func probeStdout(
        binaryExists: Bool,
        unitPresent: Bool,
        unitActive: String,
        unitSHA256: String = "",
        currentLink: String = "",
        systemd: String = "yes"
    ) -> String {
        """
        __CMUX_VPS_HOME__=/home/dev
        __CMUX_VPS_UID__=1000
        __CMUX_VPS_UNAME_OS__=Linux
        __CMUX_VPS_UNAME_ARCH__=x86_64
        __CMUX_VPS_GOOS__=linux
        __CMUX_VPS_GOARCH__=amd64
        __CMUX_VPS_DISTRO_ID__=debian
        __CMUX_VPS_DISTRO_PRETTY__=Debian 12
        __CMUX_VPS_SYSTEMD__=\(systemd)
        __CMUX_VPS_BINARY_EXISTS__=\(binaryExists ? "yes" : "no")
        __CMUX_VPS_BINARY_SHA256__=\(binaryExists ? "aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899" : "")
        __CMUX_VPS_CURRENT_LINK__=\(currentLink)
        __CMUX_VPS_UNIT_PRESENT__=\(unitPresent ? "yes" : "no")
        __CMUX_VPS_UNIT_SHA256__=\(unitSHA256)
        __CMUX_VPS_UNIT_ACTIVE__=\(unitActive)
        __CMUX_VPS_UNIT_ENABLED__=\(unitPresent ? "enabled" : "")
        __CMUX_VPS_LINGER__=yes
        __CMUX_VPS_INSTALLED_VERSIONS__=\(binaryExists ? "0.99.0" : "")
        """
    }

    private func daemonStatusJSON(sessions: Int, version: String = "0.99.0") -> String {
        """
        {"binary_version":"\(version)","slot":"vps","daemons":[
          {"version_dir":"\(version)","running":true,"socket":"/tmp/x.sock","pid":9,
           "version":"\(version)","uptime_seconds":5,"pty_sessions":\(sessions)}]}
        """
    }

    private func matching(_ fragment: String) -> @Sendable (String, [String]) -> Bool {
        { _, arguments in arguments.joined(separator: " ").contains(fragment) }
    }

    @Test("fresh provision runs probe, upload, unit install, and health check")
    func freshProvision() async throws {
        let convergedLayout = VPSRemoteLayout(
            homeDirectory: "/home/dev", version: "0.99.0", goOS: "linux", goArch: "amd64"
        )
        let convergedUnitSHA = VPSSystemdUnit(layout: convergedLayout, scope: .user).contentSHA256()
        let runner = FakeCommandRunner(rules: [
            .init(
                match: matching("__CMUX_VPS_HOME__"),
                result: VPSCommandResult(
                    status: 0,
                    stdout: probeStdout(binaryExists: false, unitPresent: false, unitActive: ""),
                    stderr: ""
                )
            ),
            .init(
                match: matching("serve --stdio --persistent"),
                result: VPSCommandResult(status: 0, stdout: helloOK, stderr: "")
            ),
            .init(
                match: matching("daemon-status --slot"),
                result: VPSCommandResult(status: 0, stdout: daemonStatusJSON(sessions: 0), stderr: "")
            ),
        ])
        // The post-provision re-probe reuses the first rule, so health sees the
        // pre-provision unit state; the assertions below only rely on the
        // daemon report (running, version match).
        let provisioner = VPSProvisioner(
            host: VPSHostDescriptor(destination: "dev@vps.example"),
            runner: runner,
            artifacts: FakeArtifacts()
        )

        var events: [VPSProvisioningEvent] = []
        for try await event in provisioner.provisionEvents(force: false) {
            events.append(event)
        }

        guard case .completed(let outcome)? = events.last else {
            Issue.record("missing completed event: \(events)")
            return
        }
        #expect(outcome.installedVersion == "0.99.0")
        #expect(outcome.unitScope == .user)
        #expect(!outcome.alreadyConverged)

        let commands = await runner.commandLines()
        #expect(commands.contains { $0.contains("scp") && $0.contains("dev@vps.example:") })
        #expect(commands.contains { $0.contains("chmod 755") })
        #expect(commands.contains { $0.contains("systemctl --user daemon-reload") })
        #expect(commands.contains { $0.contains("systemctl --user enable") && $0.contains("cmux-vps.service") })
        #expect(commands.contains { $0.contains("systemctl --user restart") && $0.contains("cmux-vps.service") })
        #expect(commands.contains { $0.contains("loginctl enable-linger") == false } )
        _ = convergedUnitSHA
    }

    @Test("upgrade with live sessions refuses without force")
    func upgradeRefusesLiveSessions() async throws {
        let oldLink = "/home/dev/.cmux/bin/cmuxd-remote/0.98.0/linux-amd64/cmuxd-remote"
        let runner = FakeCommandRunner(rules: [
            .init(
                match: matching("__CMUX_VPS_HOME__"),
                result: VPSCommandResult(
                    status: 0,
                    stdout: probeStdout(
                        binaryExists: false,
                        unitPresent: true,
                        unitActive: "active",
                        unitSHA256: "stale",
                        currentLink: oldLink
                    ),
                    stderr: ""
                )
            ),
            .init(
                match: matching("daemon-status --slot"),
                result: VPSCommandResult(status: 0, stdout: daemonStatusJSON(sessions: 2, version: "0.98.0"), stderr: "")
            ),
        ])
        let provisioner = VPSProvisioner(
            host: VPSHostDescriptor(destination: "dev@vps.example"),
            runner: runner,
            artifacts: FakeArtifacts()
        )

        await #expect(throws: VPSProvisioningError.liveSessionsPresent(count: 2)) {
            for try await _ in provisioner.provisionEvents(force: false) {}
        }
        let commands = await runner.commandLines()
        #expect(!commands.contains { $0.contains("scp") })
        #expect(!commands.contains { $0.contains("restart") })
    }

    @Test("remove stops and removes the unit, guarding live sessions")
    func removeGuardsSessions() async throws {
        let link = "/home/dev/.cmux/bin/cmuxd-remote/0.99.0/linux-amd64/cmuxd-remote"
        let probe = VPSCommandResult(
            status: 0,
            stdout: probeStdout(
                binaryExists: true,
                unitPresent: true,
                unitActive: "active",
                currentLink: link
            ),
            stderr: ""
        )
        let busy = FakeCommandRunner(rules: [
            .init(match: matching("__CMUX_VPS_HOME__"), result: probe),
            .init(
                match: matching("daemon-status --slot"),
                result: VPSCommandResult(status: 0, stdout: daemonStatusJSON(sessions: 1), stderr: "")
            ),
        ])
        let busyProvisioner = VPSProvisioner(
            host: VPSHostDescriptor(destination: "dev@vps.example"),
            runner: busy,
            artifacts: FakeArtifacts()
        )
        await #expect(throws: VPSProvisioningError.liveSessionsPresent(count: 1)) {
            for try await _ in busyProvisioner.removeEvents(keepSessions: false, force: false) {}
        }

        let idle = FakeCommandRunner(rules: [
            .init(match: matching("__CMUX_VPS_HOME__"), result: probe),
            .init(
                match: matching("daemon-status --slot"),
                result: VPSCommandResult(status: 0, stdout: daemonStatusJSON(sessions: 0), stderr: "")
            ),
        ])
        let idleProvisioner = VPSProvisioner(
            host: VPSHostDescriptor(destination: "dev@vps.example"),
            runner: idle,
            artifacts: FakeArtifacts()
        )
        var events: [VPSProvisioningEvent] = []
        for try await event in idleProvisioner.removeEvents(keepSessions: false, force: false) {
            events.append(event)
        }
        guard case .removed(let outcome)? = events.last else {
            Issue.record("missing removed event: \(events)")
            return
        }
        #expect(outcome.stoppedUnit)
        #expect(outcome.removedUnitFile)
        #expect(!outcome.keptSessions)
        let commands = await idle.commandLines()
        #expect(commands.contains { $0.contains("systemctl --user stop") && $0.contains("cmux-vps.service") })
        #expect(commands.contains { $0.contains("rm -f") && $0.contains(".config/systemd/user/cmux-vps.service") })
        #expect(commands.contains { $0.contains("rm -rf") && $0.contains(".cmux/vps") })
    }

    @Test("remove --keep-sessions never stops the unit")
    func removeKeepsSessions() async throws {
        let runner = FakeCommandRunner(rules: [
            .init(
                match: matching("__CMUX_VPS_HOME__"),
                result: VPSCommandResult(
                    status: 0,
                    stdout: probeStdout(binaryExists: true, unitPresent: true, unitActive: "active"),
                    stderr: ""
                )
            ),
        ])
        let provisioner = VPSProvisioner(
            host: VPSHostDescriptor(destination: "dev@vps.example"),
            runner: runner,
            artifacts: FakeArtifacts()
        )
        var events: [VPSProvisioningEvent] = []
        for try await event in provisioner.removeEvents(keepSessions: true, force: false) {
            events.append(event)
        }
        guard case .removed(let outcome)? = events.last else {
            Issue.record("missing removed event: \(events)")
            return
        }
        #expect(!outcome.stoppedUnit)
        #expect(outcome.keptSessions)
        let commands = await runner.commandLines()
        #expect(!commands.contains { $0.contains(" stop ") })
    }

    @Test("status classifies an unreachable host without throwing")
    func statusUnreachable() async {
        let runner = FakeCommandRunner(
            rules: [],
            fallback: VPSCommandResult(status: 255, stdout: "", stderr: "ssh: connect refused")
        )
        let provisioner = VPSProvisioner(
            host: VPSHostDescriptor(destination: "dev@vps.example"),
            runner: runner,
            artifacts: FakeArtifacts()
        )
        let status = await provisioner.status()
        #expect(status.health.state == .unreachable)
        #expect(status.facts == nil)
    }

    @Test("ssh argv keeps BatchMode, accept-new, and user overrides")
    func sshArgv() {
        let client = VPSSSHClient(
            host: VPSHostDescriptor(
                destination: "dev@vps.example",
                port: 2222,
                identityFile: "/keys/id",
                sshOptions: ["StrictHostKeyChecking=yes"]
            ),
            runner: FakeCommandRunner(rules: [])
        )
        let arguments = client.sshCommonArguments()
        #expect(arguments.contains("BatchMode=yes"))
        #expect(!arguments.contains("StrictHostKeyChecking=accept-new"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("2222"))
        #expect(arguments.contains("/keys/id"))

        let scp = client.scpArguments(localPath: "/tmp/bin", remotePath: "/home/dev/bin.tmp")
        #expect(scp.last == "dev@vps.example:/home/dev/bin.tmp")
        #expect(scp.contains("-P"))
    }

    @Test("registry round-trips entries in a temp home")
    func registryRoundTrip() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vps-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = VPSHostRegistry(homeDirectory: home)
        let host = VPSHostDescriptor(destination: "dev@vps.example", port: 2222)
        let entry = VPSRegisteredHost(
            host: host,
            installedVersion: "0.99.0",
            goOS: "linux",
            goArch: "amd64",
            addedAtUnix: 1_700_000_000
        )
        try await registry.upsert(entry)
        #expect(try await registry.entry(for: host) == entry)
        #expect(try await registry.entry(destination: "dev@vps.example", port: 2222)?.slot == "vps")
        #expect(try await registry.entry(destination: "dev@vps.example", port: nil) == nil)
        #expect(try await registry.allHosts().count == 1)
        #expect(try await registry.remove(host) == entry)
        #expect(try await registry.allHosts().isEmpty)
    }
}
