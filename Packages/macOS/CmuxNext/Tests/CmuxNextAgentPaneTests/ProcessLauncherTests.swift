@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The real launcher waits for the child's exit and bounds it: the exit status comes back, and a
/// child that does not end by the deadline is killed and reported as not finished.
@Suite(.timeLimit(.minutes(1))) struct ProcessLauncherTests {
    @Test func theExitStatusComesBack() async {
        let status = await ProcessLauncher().run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], environment: [:])
        #expect(status == 3)
    }

    @Test func aChildPastItsDeadlineIsKilled() async {
        let started = ContinuousClock.now
        // The deadline is the behavior under test: 200 ms against a child that would run 60 s.
        let status = await ProcessLauncher(timeout: .milliseconds(200))
            .run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], environment: [:])
        #expect(status == nil)
        #expect(ContinuousClock.now - started < .seconds(30), "the launcher waited for the child instead of its deadline")
    }

    /// The arguments reach the child one by one and as given (no shell, no splitting), also ones
    /// that start with `-` (a reply's own text goes on stdin). The stub records its argv,
    /// NUL-separated, in the file its environment names.
    @Test func theArgumentsReachTheChildAsGiven() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-argv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("acpmux")
        let out = root.appendingPathComponent("argv")
        try Data(#"""
        #!/bin/sh
        : > "$ARGV_OUT"
        for a in "$@"; do printf '%s\0' "$a" >> "$ARGV_OUT"; done
        """#.utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let arguments = AcpmuxReplySender.arguments(session: "s-1", promptID: "p-1")
            + ["a b", "--quiet", "-", "*"]
        let status = await ProcessLauncher().run(stub, arguments: arguments, environment: ["ARGV_OUT": out.path])
        #expect(status == 0)
        let recorded = try Data(contentsOf: out).split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(decoding: $0, as: UTF8.self) }
        #expect(recorded == arguments)
    }

    /// A reply's text reaches the child's stdin whole, also past the pipe buffer (a long pasted
    /// reply): the child counts the bytes it read.
    @Test func aLongInputReachesTheChildWhole() async {
        let input = Data(repeating: UInt8(ascii: "x"), count: 300_000)
        let status = await ProcessLauncher().run(URL(fileURLWithPath: "/bin/sh"),
                                                 arguments: ["-c", "n=$(wc -c | tr -d ' '); test \"$n\" = 300000"],
                                                 environment: [:], input: input)
        #expect(status == 0, "the child did not read the 300 000 input bytes")
    }

    @Test func aMissingExecutableIsNotStarted() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        let status = await ProcessLauncher().run(missing, arguments: [], environment: [:])
        #expect(status == nil)
    }
}
