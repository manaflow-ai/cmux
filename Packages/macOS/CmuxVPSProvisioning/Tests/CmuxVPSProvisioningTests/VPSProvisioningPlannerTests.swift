import Testing
@testable import CmuxVPSProvisioning

@Suite("VPSProvisioningPlanner")
struct VPSProvisioningPlannerTests {
    private func facts(
        uid: Int = 1000,
        goOS: String? = "linux",
        goArch: String? = "amd64",
        hasSystemd: Bool = true,
        binaryExists: Bool = false,
        binarySHA256: String = "",
        currentSymlinkTarget: String = "",
        unitFileExists: Bool = false,
        unitFileSHA256: String = "",
        unitActiveState: String = "",
        unitEnabledState: String = "",
        lingerEnabled: Bool = false
    ) -> VPSHostFacts {
        VPSHostFacts(
            homeDirectory: "/home/dev",
            uid: uid,
            unameOS: "Linux",
            unameArch: "x86_64",
            goOS: goOS,
            goArch: goArch,
            distroID: "debian",
            hasSystemd: hasSystemd,
            binaryExists: binaryExists,
            binarySHA256: binarySHA256,
            currentSymlinkTarget: currentSymlinkTarget,
            unitFileExists: unitFileExists,
            unitFileSHA256: unitFileSHA256,
            unitActiveState: unitActiveState,
            unitEnabledState: unitEnabledState,
            lingerEnabled: lingerEnabled
        )
    }

    private let version = "0.99.0"
    private let sha = "aa11bb22cc33dd44ee55ff6677889900aabbccddeeff00112233445566778899"

    private func convergedFacts() -> VPSHostFacts {
        let layout = VPSRemoteLayout(homeDirectory: "/home/dev", version: version, goOS: "linux", goArch: "amd64")
        let unit = VPSSystemdUnit(layout: layout, scope: .user)
        return facts(
            binaryExists: true,
            binarySHA256: sha,
            currentSymlinkTarget: layout.binaryPath,
            unitFileExists: true,
            unitFileSHA256: unit.contentSHA256(),
            unitActiveState: "active",
            unitEnabledState: "enabled",
            lingerEnabled: true
        )
    }

    @Test("fresh host gets full install, unit, enable, linger, restart, health")
    func freshInstall() throws {
        let planner = VPSProvisioningPlanner(facts: facts(), desiredVersion: version, expectedBinarySHA256: sha)
        let plan = try planner.makePlan()
        let layout = try #require(planner.layout)
        #expect(plan.steps == [
            .installBinary(version: version, remotePath: layout.binaryPath),
            .updateCurrentSymlink(target: layout.binaryPath),
            .writeUnitFile(path: "/home/dev/.config/systemd/user/cmux-vps.service", scope: .user),
            .daemonReload(scope: .user),
            .enableLinger,
            .enableUnit(scope: .user),
            .restartUnit(scope: .user),
            .verifyHealth,
        ])
        #expect(!plan.restartDisruptsActiveDaemon)
        #expect(plan.notes == [.lingerBestEffort])
        #expect(!plan.isAlreadyConverged)
    }

    @Test("root host installs a system unit and skips linger")
    func rootScope() throws {
        let planner = VPSProvisioningPlanner(
            facts: facts(uid: 0),
            desiredVersion: version,
            expectedBinarySHA256: sha
        )
        let plan = try planner.makePlan()
        #expect(plan.steps.contains(.writeUnitFile(path: "/etc/systemd/system/cmux-vps.service", scope: .system)))
        #expect(!plan.steps.contains(.enableLinger))
    }

    @Test("fully converged host plans only the health check")
    func convergedNoop() throws {
        let planner = VPSProvisioningPlanner(
            facts: convergedFacts(),
            desiredVersion: version,
            expectedBinarySHA256: sha
        )
        let plan = try planner.makePlan()
        #expect(plan.steps == [.verifyHealth])
        #expect(plan.isAlreadyConverged)
        #expect(!plan.restartDisruptsActiveDaemon)
    }

    @Test("checksum drift on the installed binary forces reinstall and restart")
    func checksumDriftRepairs() throws {
        var drifted = convergedFacts()
        drifted.binarySHA256 = String(repeating: "0", count: 64)
        let planner = VPSProvisioningPlanner(facts: drifted, desiredVersion: version, expectedBinarySHA256: sha)
        let plan = try planner.makePlan()
        let layout = try #require(planner.layout)
        #expect(plan.steps.first == .installBinary(version: version, remotePath: layout.binaryPath))
        #expect(plan.steps.contains(.restartUnit(scope: .user)))
        #expect(plan.restartDisruptsActiveDaemon)
    }

    @Test("existing binary without a comparable digest is trusted")
    func missingDigestTrustsBinary() throws {
        var existing = convergedFacts()
        existing.binarySHA256 = ""
        let planner = VPSProvisioningPlanner(facts: existing, desiredVersion: version, expectedBinarySHA256: sha)
        let plan = try planner.makePlan()
        #expect(plan.steps == [.verifyHealth])
    }

    @Test("version upgrade reinstalls, retargets symlink, and restarts the live daemon")
    func upgradeFlow() throws {
        let oldLayout = VPSRemoteLayout(homeDirectory: "/home/dev", version: "0.98.0", goOS: "linux", goArch: "amd64")
        let newLayout = VPSRemoteLayout(homeDirectory: "/home/dev", version: version, goOS: "linux", goArch: "amd64")
        let unit = VPSSystemdUnit(layout: newLayout, scope: .user)
        let upgradeFacts = facts(
            binaryExists: false,
            currentSymlinkTarget: oldLayout.binaryPath,
            unitFileExists: true,
            unitFileSHA256: unit.contentSHA256(),
            unitActiveState: "active",
            unitEnabledState: "enabled",
            lingerEnabled: true
        )
        let planner = VPSProvisioningPlanner(facts: upgradeFacts, desiredVersion: version, expectedBinarySHA256: sha)
        let plan = try planner.makePlan()
        #expect(plan.steps == [
            .installBinary(version: version, remotePath: newLayout.binaryPath),
            .updateCurrentSymlink(target: newLayout.binaryPath),
            .restartUnit(scope: .user),
            .verifyHealth,
        ])
        #expect(plan.restartDisruptsActiveDaemon)
    }

    @Test("inactive unit on a converged install restarts without disruption")
    func inactiveUnitRestarts() throws {
        var stopped = convergedFacts()
        stopped.unitActiveState = "inactive"
        let planner = VPSProvisioningPlanner(facts: stopped, desiredVersion: version, expectedBinarySHA256: sha)
        let plan = try planner.makePlan()
        #expect(plan.steps == [.restartUnit(scope: .user), .verifyHealth])
        #expect(!plan.restartDisruptsActiveDaemon)
    }

    @Test("non-systemd host installs the binary report-only")
    func nonSystemdReportOnly() throws {
        let planner = VPSProvisioningPlanner(
            facts: facts(hasSystemd: false),
            desiredVersion: version,
            expectedBinarySHA256: sha
        )
        let plan = try planner.makePlan()
        let layout = try #require(planner.layout)
        #expect(plan.steps == [
            .installBinary(version: version, remotePath: layout.binaryPath),
            .updateCurrentSymlink(target: layout.binaryPath),
            .verifyHealth,
        ])
        #expect(plan.notes == [.systemdUnavailable])
    }

    @Test("unsupported platform throws")
    func unsupportedPlatform() {
        let planner = VPSProvisioningPlanner(
            facts: facts(goOS: nil, goArch: nil),
            desiredVersion: version,
            expectedBinarySHA256: sha
        )
        #expect(throws: VPSProvisioningError.unsupportedPlatform(unameOS: "Linux", unameArch: "x86_64")) {
            try planner.makePlan()
        }
    }

    @Test("unit content drift rewrites the unit and reloads")
    func unitDriftRewrites() throws {
        var drifted = convergedFacts()
        drifted.unitFileSHA256 = String(repeating: "1", count: 64)
        let planner = VPSProvisioningPlanner(facts: drifted, desiredVersion: version, expectedBinarySHA256: sha)
        let plan = try planner.makePlan()
        #expect(plan.steps == [
            .writeUnitFile(path: "/home/dev/.config/systemd/user/cmux-vps.service", scope: .user),
            .daemonReload(scope: .user),
            .restartUnit(scope: .user),
            .verifyHealth,
        ])
        #expect(plan.restartDisruptsActiveDaemon)
    }
}
