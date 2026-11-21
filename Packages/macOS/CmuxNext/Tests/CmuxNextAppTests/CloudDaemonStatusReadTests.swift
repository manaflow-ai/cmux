import CmuxNextRemote
import Foundation
import Testing

/// The Cloud machine's agent daemon status read (``RemoteAgentDaemonStatus/cloudStatusCommand``) that the
/// keyed restart beside the harness login reads. Its script ended in an unclosed quote, so the shell refused it
/// and the read failed on every machine: the restart never ran beside the login, and every chat's start waited
/// for a refusal, a restart and a second start instead (production probe: 8.3 s in the start step). A
/// provider's exec may also run with no login profile: HOME unset, or the provider's own (`/root`).
@Suite(.serialized)
struct CloudDaemonStatusReadTests {
    private static let idleStatus = #"{"ready":true,"agentHosts":true,"liveAgents":0,"remoteSessions":0,"personKey":false}"#

    /// A fake machine: the work user's home with its cmux-tui (which prints `idleStatus` only when HOME is that
    /// home, as the real one reads its acpmux socket under HOME), and a `getent` that names that home.
    private struct Machine {
        let root: URL
        var home: URL { root.appendingPathComponent("home/cmux") }
        var bin: URL { root.appendingPathComponent("bin") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-status-\(UUID().uuidString)")
            let tui = root.appendingPathComponent("home/cmux/.cmux/bin")
            try FileManager.default.createDirectory(at: tui, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try Self.script(tui.appendingPathComponent("cmux-tui"), """
                #!/bin/sh
                [ "$*" = "acp --json daemon status" ] || exit 9
                [ "$HOME" = '\(home.path)' ] || { echo '{"running":true,"ready":false}'; exit 0; }
                echo '\(CloudDaemonStatusReadTests.idleStatus)'
                """)
            try Self.script(root.appendingPathComponent("bin/getent"), """
                #!/bin/sh
                [ "$1" = passwd ] && echo "$2:x:1000:1000::\(home.path):/bin/sh"
                """)
        }

        private static func script(_ url: URL, _ text: String) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        /// Runs the read's command as a provider's exec would: a clean environment plus `env`.
        func exec(_ env: [String: String]) throws -> (status: Int32, stdout: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", RemoteAgentDaemonStatus.cloudStatusCommand]
            process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"].merging(env) { $1 }
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }

    @Test func theScriptRunsAndReadsTheDaemon() throws {
        let machine = try Machine()
        defer { try? FileManager.default.removeItem(at: machine.root) }
        let result = try machine.exec(["HOME": machine.home.path])
        #expect(result.status == 0)
        #expect(RemoteAgentDaemonStatus(json: result.stdout)?.idleForKeyedRestart == true)
    }

    @Test func anExecWithNoHomeStillReadsTheWorkUsersDaemon() throws {
        let machine = try Machine()
        defer { try? FileManager.default.removeItem(at: machine.root) }
        let result = try machine.exec([:])
        #expect(result.status == 0)
        #expect(RemoteAgentDaemonStatus(json: result.stdout)?.idleForKeyedRestart == true)
    }

    @Test func anExecWithTheProvidersHomeStillReadsTheWorkUsersDaemon() throws {
        let machine = try Machine()
        defer { try? FileManager.default.removeItem(at: machine.root) }
        let result = try machine.exec(["HOME": "/root"])
        #expect(result.status == 0)
        #expect(RemoteAgentDaemonStatus(json: result.stdout)?.idleForKeyedRestart == true)
    }

    @Test func aMachineWithNoCmuxTuiStaysUnreadable() throws {
        let machine = try Machine()
        defer { try? FileManager.default.removeItem(at: machine.root) }
        try FileManager.default.removeItem(at: machine.home.appendingPathComponent(".cmux"))
        #expect(try machine.exec([:]).status == 82)
    }
}
