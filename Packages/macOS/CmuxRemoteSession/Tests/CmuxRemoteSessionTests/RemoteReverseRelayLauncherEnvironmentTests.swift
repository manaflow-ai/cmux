import CmuxFoundation
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Standalone relay child environment")
struct RemoteReverseRelayLauncherEnvironmentTests {
    @Test("OpenSSH ProxyCommand receives inherited or explicit identity and agent values", arguments: [false, true])
    func proxyCommandReceivesEnvironment(explicit: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-relay-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = directory.appendingPathComponent("identity")
        let environment: [String: String]? = explicit ? [
            "HOME": "/Users/relay-fixture",
            "USER": "relay-fixture",
            "SSH_AUTH_SOCK": "/tmp/relay-fixture.sock",
            "PATH": "/usr/bin:/bin",
        ] : nil
        let expected = environment ?? ProcessInfo.processInfo.environment
        // Perl observes the environment without a login shell synthesizing
        // missing HOME/USER values. No network or real agent is contacted.
        let probe = #"open(my $out, '>', $ARGV[0]) or die; print $out join("\0", map { $ENV{$_} // '' } qw(HOME USER SSH_AUTH_SOCK)); close($out); exit 1;"#
        let proxyCommand = "/usr/bin/perl -e \(probe.shellSingleQuoted) \(record.path.shellSingleQuoted)"
        let (terminations, continuation) = AsyncStream<Void>.makeStream()
        let process = try RemoteReverseRelayLauncher().launch(
            arguments: [
                "-F", "/dev/null", "-S", "none", "-T",
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=2",
                "-o", "ProxyCommand=\(proxyCommand)", "--", "relay-fixture.invalid",
            ],
            environment: environment,
            startupMarker: "unused-forward-marker",
            startupHandler: { _ in },
            terminationHandler: { _, _ in
                continuation.yield()
                continuation.finish()
            }
        )
        defer { if process.isRunning { process.terminate() } }
        var iterator = terminations.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        let observed = try String(contentsOf: record, encoding: .utf8)
            .split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        // Boolean assertions avoid dumping inherited values on failure.
        let identityMatches = observed == ["HOME", "USER", "SSH_AUTH_SOCK"].map { expected[$0] ?? "" }
        #expect(identityMatches)
        #expect(!process.isRunning)
    }
}
