@testable import CmuxNextRemote
import CryptoKit
import Foundation
import Testing

@Suite struct RemoteInstallTests {
    static let commit = "c27a76e10accf5d72007797a9413dad405cade79"
    static let linuxSHA = "2a6e45c84a4ff0a555d8cfed6d548c5b21a8a8bbae3b4c2fe739a39d26c4cb54"
    static let manifestJSON = """
    {"commit":"\(commit)","sourceCommit":"\(commit)","binaries":{
      "cmux-tui-x86_64-unknown-linux-musl":"\(linuxSHA)",
      "cmux-tui-aarch64-apple-darwin":"a73f0e516f619a28b3a861eb4ee4d87a31ec5360c3ec1d11406d11501f85f75a",
      "cmux-tui-aarch64-unknown-linux-musl":"NOT-A-HASH"}}
    """

    func manifest() throws -> CmuxTUIManifest { try CmuxTUIManifest.decode(Data(Self.manifestJSON.utf8)) }

    @Test func planPicksTheArtifactAndDigestForThePlatform() throws {
        let plan = try RemoteInstallPlan(commit: Self.commit, platform: #require(RemotePlatform(uname: "Linux x86_64")),
                                         manifest: manifest(), remoteBinary: "~/.local/bin/cmux-tui")
        #expect(plan.artifact == "cmux-tui-x86_64-unknown-linux-musl")
        #expect(plan.sha256 == Self.linuxSHA)
        #expect(plan.url.absoluteString == "https://files.cmux.com/cmux-tui/\(Self.commit)/cmux-tui-x86_64-unknown-linux-musl")
        #expect(RemoteInstallPlan.manifestURL(commit: Self.commit).absoluteString
            == "https://files.cmux.com/cmux-tui/\(Self.commit)/manifest.json")
    }

    @Test func planRefusesAManifestForAnotherCommitOrABadDigest() throws {
        let other = try CmuxTUIManifest.decode(Data(Self.manifestJSON.replacingOccurrences(of: "\"sourceCommit\":\"\(Self.commit)\"",
                                                                                            with: "\"sourceCommit\":\"\(String(repeating: "a", count: 40))\"").utf8))
        let linux = try #require(RemotePlatform(uname: "Linux x86_64"))
        #expect(throws: RemoteInstallError.commitMismatch(expected: Self.commit, found: String(repeating: "a", count: 40))) {
            try RemoteInstallPlan(commit: Self.commit, platform: linux, manifest: other, remoteBinary: "~/.local/bin/cmux-tui")
        }
        let arm = try #require(RemotePlatform(uname: "Linux aarch64"))
        #expect(throws: RemoteInstallError.badChecksum("cmux-tui-aarch64-unknown-linux-musl")) {
            try RemoteInstallPlan(commit: Self.commit, platform: arm, manifest: manifest(), remoteBinary: "~/.local/bin/cmux-tui")
        }
        let intel = try #require(RemotePlatform(uname: "Darwin x86_64"))
        #expect(throws: RemoteInstallError.missingArtifact("cmux-tui-x86_64-apple-darwin")) {
            try RemoteInstallPlan(commit: Self.commit, platform: intel, manifest: manifest(), remoteBinary: "~/.local/bin/cmux-tui")
        }
        #expect(throws: RemoteInstallError.badCommit) {
            try RemoteInstallPlan(commit: "main", platform: linux, manifest: manifest(), remoteBinary: "~/.local/bin/cmux-tui")
        }
    }

    @Test func fetchScriptResumesOverHTTP11VerifiesAndNeverEscalates() throws {
        let plan = try RemoteInstallPlan(commit: Self.commit, platform: #require(RemotePlatform(uname: "Linux x86_64")),
                                         manifest: manifest(), remoteBinary: "~/.local/bin/cmux-tui")
        let script = plan.fetchScript
        #expect(script.contains("--http1.1"))
        #expect(script.contains("-C -"), "curl resumes a partial download")
        #expect(script.contains("wget -c"), "wget resumes a partial download")
        #expect(script.contains(Self.linuxSHA))
        #expect(script.contains("sha256sum") && script.contains("shasum -a 256"))
        #expect(script.contains("\"$HOME\"/'.local/bin/cmux-tui'"))
        #expect(script.contains("mv -f"))
        #expect(script.contains("remote-probe --json"), "the staged binary must run before it replaces anything")
        #expect(!script.contains("sudo"))
        #expect(!script.contains(" su "))
        #expect(!script.contains("chown"))
        // The replaced file is renamed into place only after the digest matched.
        let verify = try #require(script.range(of: "cmux-install-checksum"))
        let move = try #require(script.range(of: "mv -f"))
        #expect(verify.lowerBound < move.lowerBound)
    }

    @Test func uploadScriptReadsTheBinaryFromStdinAndVerifiesItToo() throws {
        let plan = try RemoteInstallPlan(commit: Self.commit, platform: #require(RemotePlatform(uname: "Linux x86_64")),
                                         manifest: manifest(), remoteBinary: "/opt/me/cmux-tui")
        let script = plan.uploadScript
        #expect(plan.uploadCommand == "mkdir -p /opt/me && cat > /opt/me/.cmux-tui-c27a76e10acc.partial")
        #expect(script.contains("/opt/me/.cmux-tui-c27a76e10acc.partial") || script.contains("$dir/.cmux-tui-c27a76e10acc.partial"))
        #expect(script.contains(Self.linuxSHA))
        #expect(script.contains("'/opt/me/cmux-tui'"))
        #expect(!script.contains("curl") && !script.contains("wget"))
        #expect(!script.contains("sudo"))
    }

    @Test func scriptFailuresBecomeTypedErrors() {
        #expect(RemoteInstallError.fromScript(status: 13, stderr: "cmux-install-nodownloader") == .noDownloader)
        #expect(RemoteInstallError.fromScript(status: 14, stderr: "curl: (92) HTTP/2 stream 1 was not closed cleanly") == .downloadFailed("curl: (92) HTTP/2 stream 1 was not closed cleanly"))
        #expect(RemoteInstallError.fromScript(status: 15, stderr: "cmux-install-checksum expected aa got bb")
            == .checksumMismatch(expected: "aa", actual: "bb"))
        #expect(RemoteInstallError.fromScript(status: 16, stderr: "Exec format error") == .unrunnable("Exec format error"))
        #expect(RemoteInstallError.fromScript(status: 17, stderr: "mkdir: Permission denied") == .notWritable("mkdir: Permission denied"))
        #expect(RemoteInstallError.noDownloader.fallsBackToUpload)
        #expect(RemoteInstallError.downloadFailed("x").fallsBackToUpload)
        #expect(!RemoteInstallError.checksumMismatch(expected: "a", actual: "b").fallsBackToUpload)
    }

    @Test func localChecksumStreamsTheFileAndRejectsAMismatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("blob")
        var bytes = Data()
        for index in 0..<(3 * 1024 * 1024 + 17) { bytes.append(UInt8(truncatingIfNeeded: index &* 31)) }
        try bytes.write(to: file)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try SHA256File.hex(of: file) == expected)
        try SHA256File.verify(file, expected: expected.uppercased())
        #expect(throws: RemoteInstallError.checksumMismatch(expected: String(repeating: "0", count: 64), actual: expected)) {
            try SHA256File.verify(file, expected: String(repeating: "0", count: 64))
        }
    }

    @Test func localDownloadResumesOverHTTP11() throws {
        let plan = try RemoteInstallPlan(commit: Self.commit, platform: #require(RemotePlatform(uname: "Linux x86_64")),
                                         manifest: manifest(), remoteBinary: "~/.local/bin/cmux-tui")
        let argv = plan.localDownloadArguments(to: URL(fileURLWithPath: "/tmp/x.partial"))
        #expect(argv.contains("--http1.1"))
        #expect(argv.contains("-C") && argv.contains("-"))
        #expect(argv.contains("--proto") && argv.contains("=https"))
        #expect(argv.last == plan.url.absoluteString)
    }

    @Test func restartScriptStopsOnlyTheSidecarAndTheNamedDaemon() throws {
        let host = try SSHHost(destination: SSHDestination(parsing: "box"), session: "work")
        let script = RemoteInstallPlan.restartScript(host: host, daemonPID: 4242)
        #expect(script.contains("remote stop --session 'work'"))
        #expect(script.contains("kill -TERM 4242"))
        #expect(script.contains("--session work"), "the pid must belong to that session's cmux-tui")
        #expect(!script.contains("server stop"), "server stop ends every terminal")
        #expect(!script.contains("kill -9") && !script.contains("KILL"))
        #expect(!script.contains("__terminal-host"), "terminal hosts are never signalled")
        let noPID = RemoteInstallPlan.restartScript(host: host, daemonPID: nil)
        #expect(!noPID.contains("kill"))
    }
}
