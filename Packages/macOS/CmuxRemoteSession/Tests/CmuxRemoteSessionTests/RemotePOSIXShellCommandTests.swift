import Foundation
import Testing
@testable import CmuxRemoteSession

// `sshd` runs `<login shell> -c <command>`, so a command built for `ssh` has
// to survive the account's login shell before `sh` sees the script. csh and
// tcsh refuse a newline inside single quotes (`Unmatched '`), which is how the
// daemon bootstrap failed for a tcsh account
// (https://github.com/manaflow-ai/cmux/issues/16968). Each case runs the
// command the way sshd would, under every shell this machine has, and compares
// it with running the script directly.
@Suite("Remote POSIX shell command")
struct RemotePOSIXShellCommandTests {
    private struct Outcome: Equatable {
        var status: Int32
        var stdout: String
    }

    // A runner without one of these shells skips the tests that need it.
    static let hasTcsh = FileManager.default.isExecutableFile(atPath: "/bin/tcsh")
    static let hasDash = FileManager.default.isExecutableFile(atPath: "/bin/dash")

    static let loginShells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/ksh", "/bin/csh", "/bin/tcsh"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }

    static let scripts: [String] = [
        "echo one",
        "echo one\necho two",
        "if [ 1 -eq 1 ]; then\n  echo yes\nelse\n  echo no\nfi\n",
        "for word in a b c; do\n  printf '%s-' \"$word\"\ndone\necho",
        "echo \"it's\" 'a \"quoted\" word' \"and a \\\\ backslash\"",
        "printf '%s\\n' 'tab\there' 'percent % sign' 'bang ! mark' 'a\\nb' '\\c' '\\0101'",
        "value='single'\necho \"$value ${value}s $(echo sub) `echo tick`\"",
        "echo \"args: $# zero: $0\"",
        "cat <<'EOT'\nhere $HOME 'doc'\n  indented\nEOT\n",
        "cat",
        "while IFS= read -r line; do\n  echo \"got $line\"\ndone",
        "echo before\nexit 7\necho after",
        "# a comment with 'quotes'\n\n\necho after-blank-lines\n\n",
        "echo 'café ✓ 日本語'",
        // csh and tcsh expand `!` as history even inside single quotes.
        "echo 'a!b' \"!x\" !y z!\ncase 7 in\n  ''|*[!0-9]*) echo bad ;;\n  *) echo digits ;;\nesac",
        "sleep 0 &\nwait \"$!\"\necho \"waited $?\"",
        "echo abc12 | sed -E 's/a(b)c([0-9]+)$/\\1\\2\\\\/'",
        "echo \"leftover: ${s-unset} $#\"",
    ]

    /// Startup files a csh or tcsh account may have, each of which changes
    /// how the command line is read before `sh` sees it.
    static let cshStartupFiles = ["", "set backslash_quote\n", "set noglob\nset noclobber\n", "set histchars = '!^'\n"]

    @Test("a script runs the same under every login shell", arguments: loginShells, scripts)
    func scriptRunsTheSameUnderEveryLoginShell(loginShell: String, script: String) throws {
        let input = "first line\nsecond 'line'\n"
        let expected = try runDirectly(script, input: input)
        let command = RemotePOSIXShellCommand(script: script).commandLine
        #expect(try run(loginShell, ["-c", command], input: input) == expected)
    }

    @Test(
        "a script runs the same under tcsh, whatever its startup file sets",
        .enabled(if: hasTcsh),
        arguments: cshStartupFiles, scripts
    )
    func scriptRunsTheSameUnderConfiguredTcsh(startupFile: String, script: String) throws {
        let input = "first line\nsecond 'line'\n"
        let expected = try runDirectly(script, input: input)
        let command = RemotePOSIXShellCommand(script: script).commandLine
        #expect(try run("/bin/tcsh", ["-c", command], input: input, cshStartupFile: startupFile) == expected)
    }

    /// Every character of the scripts cmux really sends has to arrive. A quoted
    /// here-document prints its body untouched, so the script text goes in as
    /// the body and has to come back out the same.
    @Test("the scripts cmux sends arrive intact under every login shell", arguments: loginShells)
    func sentScriptsArriveIntact(loginShell: String) throws {
        let sent: [String] = [
            RemoteSessionCoordinator.remotePlatformProbeScript(version: "1.2.3"),
            RemoteSessionCoordinator.remoteDaemonFinalizeScript(
                remoteTempPath: "/home/o'brien/.cmux/bin/cmuxd-remote.tmp-1",
                remotePath: "/home/o'brien/.cmux/bin/cmuxd-remote",
                expectedByteCount: 1234,
                expectedSHA256: String(repeating: "a", count: 64)
            ),
            RemoteSessionCoordinator.remoteDaemonTemporaryCleanupScript(
                remotePath: "/home/me/.cmux/bin/cmuxd-remote",
                currentTemporaryPath: "/home/me/.cmux/bin/cmuxd-remote.tmp-1"
            ),
            RemoteSessionCoordinator.remoteDaemonDiagnosticsScript(
                remotePath: "/home/me/.cmux/bin/cmuxd-remote",
                version: "1.2.3",
                persistentDaemonSlot: "slot"
            ),
            RemoteSessionCoordinator.remotePortScanScript(
                ttyNames: ["pts/1", "pts/2"],
                excluding: [22, 8080],
                protecting: ["pts/1": [3000]]
            ),
            RemoteSessionCoordinator.remoteAllPortsScanScript(excluding: [22]),
            RemoteSessionCoordinator.remoteCLIWrapperScript(),
        ]
        for script in sent {
            #expect(script.contains("\n"))
            let delimiter = "CMUX_SENT_SCRIPT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let echoing = "cat <<'\(delimiter)'\n\(script)\n\(delimiter)\n"
            let command = RemotePOSIXShellCommand(script: echoing).commandLine
            let outcome = try run(loginShell, ["-c", command], input: "")
            #expect(outcome == Outcome(status: 0, stdout: script + "\n"))
        }
    }

    @Test("the command is one line, whatever the script holds", arguments: scripts)
    func commandIsOneLine(script: String) {
        let command = RemotePOSIXShellCommand(script: script).commandLine
        #expect(!command.contains("\n"))
        #expect(!command.contains("\r"))
    }

    /// Linux hosts usually have dash as `sh`, with its own `printf` and `eval`.
    @Test("a script runs the same when the remote sh is dash", .enabled(if: hasTcsh && hasDash), arguments: scripts)
    func scriptRunsTheSameUnderDash(script: String) throws {
        let dash = "/bin/dash"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-sh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("sh").path,
            withDestinationPath: dash
        )
        let path = "\(directory.path):/usr/bin:/bin"
        let input = "first line\nsecond 'line'\n"
        let expected = try runDirectly(script, input: input, path: path)
        let command = RemotePOSIXShellCommand(script: script).commandLine
        #expect(try run("/bin/tcsh", ["-c", command], input: input, path: path) == expected)
    }

    /// The scripts the bootstrap really sends, under the shell from the report.
    @Test("the bootstrap probe reports the platform to a tcsh account", .enabled(if: hasTcsh))
    func bootstrapProbeRunsUnderTcsh() throws {
        let script = RemoteSessionCoordinator.remotePlatformProbeScript(version: "1.2.3")
        #expect(script.contains("\n"))
        let command = RemotePOSIXShellCommand(script: script).commandLine
        let outcome = try run("/bin/tcsh", ["-c", command], input: "")
        #expect(outcome.status == 0)
        #expect(outcome.stdout.contains(RemoteSessionCoordinator.remotePlatformProbeOSMarker))
        #expect(outcome.stdout.contains(RemoteSessionCoordinator.remotePlatformProbeArchMarker))
        // The probe prints the home directory, which differs from run to run.
        func withoutHome(_ outcome: Outcome) -> [Substring] {
            outcome.stdout.split(separator: "\n")
                .filter { !$0.hasPrefix(RemoteSessionCoordinator.remotePlatformProbeHomeMarker) }
        }
        #expect(outcome.stdout.contains(RemoteSessionCoordinator.remotePlatformProbeHomeMarker))
        #expect(withoutHome(outcome) == withoutHome(try runDirectly(script, input: "")))
    }

    /// Runs `script` as `sh -c <script>` with no login shell in between.
    private func runDirectly(_ script: String, input: String, path: String = "/usr/bin:/bin") throws -> Outcome {
        try run("/usr/bin/env", ["sh", "-c", script], input: input, path: path)
    }

    /// Runs `executable` with a home that holds no startup file but the one given.
    private func run(
        _ executable: String,
        _ arguments: [String],
        input: String,
        path: String = "/usr/bin:/bin",
        cshStartupFile: String = ""
    ) throws -> Outcome {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        if !cshStartupFile.isEmpty {
            try cshStartupFile.write(to: home.appendingPathComponent(".cshrc"), atomically: true, encoding: .utf8)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["HOME": home.path, "PATH": path, "LC_ALL": "en_US.UTF-8"]
        process.currentDirectoryURL = home
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, stdout: String(decoding: output, as: UTF8.self))
    }
}
