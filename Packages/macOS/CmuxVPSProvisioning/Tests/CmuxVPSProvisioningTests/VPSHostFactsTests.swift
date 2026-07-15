import Testing
@testable import CmuxVPSProvisioning

@Suite("VPSHostFacts parsing")
struct VPSHostFactsTests {
    private func probeOutput(
        home: String = "/home/dev",
        uid: String = "1000",
        goOS: String = "linux",
        goArch: String = "amd64",
        systemd: String = "yes",
        binaryExists: String = "no",
        installedVersions: String = ""
    ) -> String {
        """
        __CMUX_VPS_HOME__=\(home)
        __CMUX_VPS_UID__=\(uid)
        __CMUX_VPS_UNAME_OS__=Linux
        __CMUX_VPS_UNAME_ARCH__=x86_64
        __CMUX_VPS_GOOS__=\(goOS)
        __CMUX_VPS_GOARCH__=\(goArch)
        __CMUX_VPS_DISTRO_ID__=debian
        __CMUX_VPS_DISTRO_PRETTY__=Debian GNU/Linux 12 (bookworm)
        __CMUX_VPS_SYSTEMD__=\(systemd)
        __CMUX_VPS_BINARY_EXISTS__=\(binaryExists)
        __CMUX_VPS_BINARY_SHA256__=ABCDEF
        __CMUX_VPS_CURRENT_LINK__=/home/dev/.cmux/bin/cmuxd-remote/0.98.0/linux-amd64/cmuxd-remote
        __CMUX_VPS_UNIT_PRESENT__=yes
        __CMUX_VPS_UNIT_SHA256__=00FF
        __CMUX_VPS_UNIT_ACTIVE__=active
        __CMUX_VPS_UNIT_ENABLED__=enabled
        __CMUX_VPS_LINGER__=yes
        __CMUX_VPS_INSTALLED_VERSIONS__=\(installedVersions)
        """
    }

    @Test("full probe output parses with normalization")
    func parsesFullOutput() throws {
        let facts = try VPSHostFacts.parse(stdout: probeOutput(installedVersions: "0.98.0,0.99.0"))
        #expect(facts.homeDirectory == "/home/dev")
        #expect(facts.uid == 1000)
        #expect(facts.goOS == "linux")
        #expect(facts.goArch == "amd64")
        #expect(facts.distroID == "debian")
        #expect(facts.distroPrettyName == "Debian GNU/Linux 12 (bookworm)")
        #expect(facts.hasSystemd)
        #expect(!facts.binaryExists)
        #expect(facts.binarySHA256 == "abcdef")
        #expect(facts.currentSymlinkTarget == "/home/dev/.cmux/bin/cmuxd-remote/0.98.0/linux-amd64/cmuxd-remote")
        #expect(facts.unitFileExists)
        #expect(facts.unitFileSHA256 == "00ff")
        #expect(facts.unitIsActive)
        #expect(facts.unitEnabledState == "enabled")
        #expect(facts.lingerEnabled)
        #expect(facts.installedVersions == ["0.98.0", "0.99.0"])
        #expect(facts.unitScope == .user)
    }

    @Test("unsupported platform markers map to nil GOOS/GOARCH")
    func unsupportedPlatform() throws {
        let facts = try VPSHostFacts.parse(
            stdout: probeOutput(goOS: "unsupported", goArch: "unsupported")
        )
        #expect(facts.goOS == nil)
        #expect(facts.goArch == nil)
    }

    @Test("uid 0 selects the system unit scope")
    func rootScope() throws {
        let facts = try VPSHostFacts.parse(stdout: probeOutput(uid: "0"))
        #expect(facts.unitScope == .system)
    }

    @Test("noise lines around markers are ignored")
    func toleratesNoise() throws {
        let noisy = "motd banner\n" + probeOutput() + "\ntrailing noise"
        let facts = try VPSHostFacts.parse(stdout: noisy)
        #expect(facts.homeDirectory == "/home/dev")
    }

    @Test("missing home marker throws probeParseFailed")
    func missingHomeThrows() {
        let withoutHome = probeOutput()
            .split(separator: "\n")
            .filter { !$0.hasPrefix("__CMUX_VPS_HOME__=") }
            .joined(separator: "\n")
        #expect(throws: VPSProvisioningError.probeParseFailed(
            detail: "probe output is missing markers: __CMUX_VPS_HOME__="
        )) {
            try VPSHostFacts.parse(stdout: withoutHome)
        }
    }

    @Test("truncated probe output is rejected instead of read as negative facts")
    func truncatedProbeThrows() {
        // Cut the probe mid-stream after the platform markers: the systemd,
        // binary, unit, and linger markers are all absent.
        let truncated = probeOutput()
            .split(separator: "\n")
            .prefix(6)
            .joined(separator: "\n")
        #expect(throws: VPSProvisioningError.self) {
            try VPSHostFacts.parse(stdout: truncated)
        }
    }

    @Test("malformed boolean marker is rejected")
    func malformedBooleanThrows() {
        let corrupted = probeOutput()
            .replacingOccurrences(of: "__CMUX_VPS_SYSTEMD__=yes", with: "__CMUX_VPS_SYSTEMD__=maybe")
        #expect(throws: VPSProvisioningError.self) {
            try VPSHostFacts.parse(stdout: corrupted)
        }
    }

    @Test("probe script pins the bootstrap-compatible binary path and sanitizes versions")
    func probeScriptShape() {
        let script = VPSHostProbeScript(version: "0.99.0").script()
        #expect(script.contains(#"cmux_binary_path="$HOME/.cmux/bin/cmuxd-remote/0.99.0/${cmux_go_os}-${cmux_go_arch}/cmuxd-remote""#))
        #expect(script.contains("cmux-vps.service"))
        #expect(VPSHostProbeScript(version: "evil; rm -rf /").version == "dev")
        #expect(VPSHostProbeScript(version: "..").version == "dev")
    }
}
