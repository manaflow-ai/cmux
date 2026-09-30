@testable import CmuxNextRemote
import Foundation
import Testing

@Suite struct SSHProbeTests {
    static let probeJSON = """
    {"app":"cmux-tui","arch":"x86_64","build_identity":"c27a76e10accf5d72007797a9413dad405cade79","capabilities":["wireguard-hub"],\
    "distribution_version":"0.0.0-r2.sha-c27a76e","npm_bootstrap_version":null,"os":"linux","remote_protocol":5,"version":"0.1.0"}
    """

    @Test func platformsMapToThePublishedArtifacts() {
        #expect(RemotePlatform(uname: "Linux x86_64")?.artifact == "cmux-tui-x86_64-unknown-linux-musl")
        #expect(RemotePlatform(uname: "Linux aarch64")?.artifact == "cmux-tui-aarch64-unknown-linux-musl")
        #expect(RemotePlatform(uname: "Linux arm64")?.artifact == "cmux-tui-aarch64-unknown-linux-musl")
        #expect(RemotePlatform(uname: "Darwin arm64")?.artifact == "cmux-tui-aarch64-apple-darwin")
        #expect(RemotePlatform(uname: "Darwin x86_64")?.artifact == "cmux-tui-x86_64-apple-darwin")
        #expect(RemotePlatform(uname: "Linux armv7l") == nil)
        #expect(RemotePlatform(uname: "FreeBSD amd64") == nil)
        #expect(RemotePlatform(uname: "MINGW64_NT-10.0 x86_64") == nil)
        #expect(RemotePlatform(uname: "Linux x86_64")?.label == "Linux x86_64")
        #expect(RemotePlatform(uname: "Darwin arm64")?.label == "macOS arm64")
    }

    @Test func reportReadsUnameAndAnInstalledBinary() throws {
        let report = try #require(SSHProbeReport.parse(stdout: "cmux-probe-uname: Linux x86_64\n\(Self.probeJSON)\ncmux-probe-end\n"))
        #expect(report.platform == RemotePlatform(uname: "Linux x86_64"))
        guard case .installed(let probe) = report.binary else { Issue.record("expected installed"); return }
        #expect(probe.app == "cmux-tui")
        #expect(probe.remoteProtocol == 5)
        #expect(probe.buildIdentity == "c27a76e10accf5d72007797a9413dad405cade79")
    }

    @Test func reportTellsMissingFromUnrunnable() throws {
        let missing = try #require(SSHProbeReport.parse(stdout: "cmux-probe-uname: Darwin arm64\ncmux-probe-missing\ncmux-probe-end\n"))
        #expect(missing.binary == .missing)
        let broken = try #require(SSHProbeReport.parse(stdout: "cmux-probe-uname: Linux aarch64\ncmux-probe-failed 126\ncmux-probe-end\n"))
        #expect(broken.binary == .unrunnable("exit 126"))
        let garbage = try #require(SSHProbeReport.parse(stdout: "cmux-probe-uname: Linux aarch64\nnot json\ncmux-probe-end\n"))
        #expect(garbage.binary == .unrunnable("not json"))
        // A login banner or motd on stdout does not confuse the parse.
        let banner = try #require(SSHProbeReport.parse(stdout: "Welcome!\ncmux-probe-uname: Linux x86_64\ncmux-probe-missing\ncmux-probe-end\n"))
        #expect(banner.binary == .missing)
        #expect(SSHProbeReport.parse(stdout: "") == nil)
        #expect(SSHProbeReport.parse(stdout: "cmux-probe-uname: Linux x86_64\n") == nil)
    }

    @Test func probeScriptIsPlainShAndNeverEscalates() {
        let script = SSHProbeReport.script(remoteBinary: "~/.local/bin/cmux-tui")
        #expect(script.contains("uname -s -m"))
        #expect(script.contains("\"$HOME\"/'.local/bin/cmux-tui'"))
        #expect(script.contains("remote-probe --json"))
        #expect(!script.contains("sudo"))
        #expect(!script.contains("bash"))
    }

    @Test func assessmentDecidesWhatTheMachineNeeds() throws {
        let linux = RemotePlatform(uname: "Linux x86_64")
        let installed = try JSONDecoder().decode(RemoteProbe.self, from: Data(Self.probeJSON.utf8))
        #expect(InstallNeed.assess(SSHProbeReport(platform: linux, binary: .installed(installed)), localProtocol: 5) == .none)
        #expect(InstallNeed.assess(SSHProbeReport(platform: linux, binary: .missing), localProtocol: 5) == .missing)
        #expect(InstallNeed.assess(SSHProbeReport(platform: linux, binary: .unrunnable("exit 126")), localProtocol: 5) == .unrunnable("exit 126"))
        #expect(InstallNeed.assess(SSHProbeReport(platform: linux, binary: .installed(installed)), localProtocol: 6)
            == .protocolMismatch(remote: 5, local: 6))
        var other = installed
        other.app = "tmux"
        #expect(InstallNeed.assess(SSHProbeReport(platform: linux, binary: .installed(other)), localProtocol: 5) == .wrongApp("tmux"))
        #expect(InstallNeed.assess(SSHProbeReport(platform: nil, binary: .missing), localProtocol: 5) == .unsupportedPlatform)
        #expect(InstallNeed.none.canInstall == false)
        #expect(InstallNeed.missing.canInstall)
        #expect(InstallNeed.unsupportedPlatform.canInstall == false)
    }

    @Test func localProtocolComesFromTheBundledProbe() throws {
        #expect(try RemoteProbe.decode(Self.probeJSON).remoteProtocol == 5)
        #expect(throws: (any Error).self) { try RemoteProbe.decode("{}") }
    }
}

@Suite struct SSHFailureTests {
    @Test func successIsNoFailure() {
        #expect(SSHFailure.classify(status: 0, stderr: "") == nil)
    }

    @Test func authenticationFailures() {
        let denied = SSHFailure.classify(status: 255, stderr: "lawrence@mini: Permission denied (publickey,password,keyboard-interactive).")
        #expect(denied == .authFailed("lawrence@mini: Permission denied (publickey,password,keyboard-interactive)."))
        #expect(SSHFailure.classify(status: 255, stderr: "Received disconnect from 1.2.3.4 port 22:2: Too many authentication failures")?.kind == .authFailed)
    }

    @Test func hostKeyProblemsAreNeverBypassed() {
        let changed = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Host key verification failed.
        """
        #expect(SSHFailure.classify(status: 255, stderr: changed)?.kind == .hostKeyUntrusted)
        #expect(SSHFailure.classify(status: 255, stderr: "No ED25519 host key is known for box and you have requested strict checking.\nHost key verification failed.")?.kind == .hostKeyUntrusted)
    }

    @Test func networkFailuresAreUnreachable() {
        for line in ["ssh: Could not resolve hostname nope: nodename nor servname provided, or not known",
                     "ssh: connect to host 10.0.0.9 port 22: Connection refused",
                     "ssh: connect to host 10.0.0.9 port 22: Operation timed out",
                     "ssh: connect to host box port 22: No route to host",
                     "ssh: connect to host box port 22: Network is unreachable",
                     "kex_exchange_identification: Connection closed by remote host",
                     "Connection timed out during banner exchange",
                     "Connection closed by 10.0.0.9 port 22"] {
            #expect(SSHFailure.classify(status: 255, stderr: line)?.kind == .unreachable, "\(line)")
        }
    }

    @Test func otherFailuresKeepTheLastLine() {
        let failure = SSHFailure.classify(status: 2, stderr: "motd\nsh: 1: something broke\n")
        #expect(failure == .remoteFailed("sh: 1: something broke"))
        #expect(SSHFailure.classify(status: 255, stderr: "")?.kind == .remoteFailed)
    }
}
