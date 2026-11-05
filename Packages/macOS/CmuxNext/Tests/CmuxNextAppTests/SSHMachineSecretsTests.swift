@testable import CmuxNextCloud
@testable import CmuxNextRemote
import Foundation
import Testing

/// `cmux cloud deliver-secrets` to an own machine (SSHMachineSecrets): the Cloud receiver and protocol,
/// carried over the person's own ssh. A stand-in ssh runs the remote command here (on a pty for `-tt`,
/// through `script`), so the delivery below runs the real receiver end to end against a scratch home.
@Suite(.serialized)
struct SSHMachineSecretsTests {
    @Test func aPeersSSHURLGivesItsSSHDestinationWithoutTheDaemonsPort() throws {
        #expect(SSHMachineSecrets.destination(peerURL: "ssh://ann@dev-box:47811")?.sshArgument == "ann@dev-box")
        #expect(SSHMachineSecrets.destination(peerURL: "ssh://dev-box")?.sshArgument == "dev-box")
        #expect(SSHMachineSecrets.destination(peerURL: "ssh://dev-box:47811")?.port == nil, "47811 is the daemon's, not ssh's")
        #expect(SSHMachineSecrets.destination(peerURL: "ssh://[fd7a::1]:47811")?.sshArgument == "fd7a::1")
        for other in ["ws://100.64.0.1:47811", "wss://host", "dev-box", "ssh://-oProxyCommand=x", "ssh://a b"] {
            #expect(SSHMachineSecrets.destination(peerURL: other) == nil, "\(other)")
        }
    }

    @Test func theReceiverRunsOnAPtyOfItsOwnWithTheAppsSSHOptions() throws {
        let destination = try SSHDestination(parsing: "ann@dev-box:2222")
        let command = try #require(SSHMachineSecrets.remoteCommand(["sh", SSHMachineSecrets.receiverPath, SSHMachineSecrets.ticketPath("ab12")]))
        #expect(command == #"sh "$HOME/.cmux/machine-config/receive-secrets" "$HOME/.cmux/machine-config/receive-secrets.ab12.ticket""#)
        let argv = SSHCommandLine().pty(destination, command)
        #expect(Array(argv.prefix(2)) == ["/usr/bin/ssh", "-tt"])
        #expect(argv.contains("-oForwardAgent=no") && argv.contains("-oBatchMode=yes"))
        #expect(Array(argv.suffix(5)) == ["-p", "2222", "--", "ann@dev-box", command])
        // Only the fixed receiver paths pass: nothing a login shell would read as more than a word.
        for word in ["a b", "x\"y", "$(id)", "`id`", "a;b", ""] {
            #expect(SSHMachineSecrets.remoteCommand(["sh", word]) == nil, "\(word)")
        }
    }

    @Test func theInstallWritesTheReceiverAndItsTicketPrivatelyAndNoValue() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ticket = CloudMachineSecrets.ticket(nonce: "ab12", key: "cd34", names: ["API_KEY"])
        let script = SSHMachineSecrets.installScript(ticket: ticket, word: "w0rd")
        let ran = try Self.shell(script, home: home)
        #expect(ran == 0)
        let folder = home.appendingPathComponent(".cmux/machine-config")
        #expect(try String(contentsOf: folder.appendingPathComponent("receive-secrets"), encoding: .utf8) == CloudMachineSecrets.receiver + "\n")
        #expect(try Data(contentsOf: folder.appendingPathComponent("receive-secrets.w0rd.ticket")) == ticket)
        #expect(try Self.mode(folder) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".receive-secrets.w0rd").path), "the receiver goes in by a rename")
        #expect(try Self.mode(folder.appendingPathComponent("receive-secrets.w0rd.ticket")) == 0o600)
    }

    /// The whole delivery over the stand-in ssh: the receiver writes the file (0600) with the values,
    /// removes its ticket, and answers with the token only it can make.
    /// The stand-in's PATH has no sha256sum, so the receiver takes macOS's shasum, as on a Mac.
    @Test func aDeliveryOverSSHWritesTheMachinesSecretsFile() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = try Self.standInSSH(in: home)
        let link = SSHMachineSecrets.link(to: try SSHDestination(parsing: "ann@own-machine"),
                                          environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"],
                                          commandLine: SSHCommandLine(sshBinary: ssh.path), word: "a1b2")
        let values = [(name: "API_KEY", value: "sk-live-1'23"), (name: "DATABASE_URL", value: "postgres://u:p@db/app")]
        let count = try await CloudMachineSecrets.deliver(values, over: link, receiverAt: SSHMachineSecrets.receiverPath,
                                                          ticketAt: SSHMachineSecrets.ticketPath("a1b2"))
        #expect(count == 2)
        let file = home.appendingPathComponent(".config/cmux/machine-secrets.env")
        #expect(try String(contentsOf: file, encoding: .utf8) == "export API_KEY='sk-live-1'\\''23'\nexport DATABASE_URL='postgres://u:p@db/app'\n")
        #expect(try Self.mode(file) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".cmux/machine-config/receive-secrets.a1b2.ticket").path))
    }

    /// An ssh that cannot reach the machine stops the delivery before any value is read off the pty,
    /// with ssh's own words.
    @Test func anUnreachableMachineStopsAtTheInstallWithSSHsWords() async throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appendingPathComponent("ssh")
        try "#!/bin/sh\necho 'ssh: connect to host own-machine port 22: Connection refused' >&2\nexit 255\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        let link = SSHMachineSecrets.link(to: try SSHDestination(parsing: "own-machine"), environment: ["HOME": home.path],
                                          commandLine: SSHCommandLine(sshBinary: ssh.path), word: "c3d4")
        await #expect(throws: SSHMachineSecrets.Unreachable(message: "ssh: connect to host own-machine port 22: Connection refused")) {
            _ = try await CloudMachineSecrets.deliver([(name: "API_KEY", value: "sk-live-123")], over: link,
                                                      receiverAt: SSHMachineSecrets.receiverPath, ticketAt: SSHMachineSecrets.ticketPath("c3d4"))
        }
    }

    /// An ssh that stops reading (a stalled link, a receiver gone after READY) ends the typing at its
    /// deadline instead of holding the delivery.
    @Test func aStalledSSHEndsTheTypingAtItsDeadline() async throws {
        let run = try Self.standIn("echo ready\nexec sleep 30\n")
        defer { try? FileManager.default.removeItem(at: run.home) }
        _ = try await run.run.waitFor("ready", seconds: 10)
        let started = ContinuousClock.now
        await #expect(throws: CloudMachineSecrets.DeliveryFailed(reason: "eof")) {
            try await run.run.type(Data(repeating: 0x41, count: 1 << 20), seconds: 1)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        await run.run.stop()
    }

    /// One deadline for the whole payload: an ssh that keeps taking a little (1 KiB every 0.2 s) does
    /// not keep the typing past it.
    @Test func aTricklingSSHEndsTheTypingAtTheOneDeadline() async throws {
        let run = try Self.standIn("echo ready\nwhile :; do dd bs=1024 count=1 2>/dev/null >/dev/null || exit 0; sleep 0.2; done\n")
        defer { try? FileManager.default.removeItem(at: run.home) }
        _ = try await run.run.waitFor("ready", seconds: 10)
        let started = ContinuousClock.now
        await #expect(throws: CloudMachineSecrets.DeliveryFailed(reason: "eof")) {
            try await run.run.type(Data(repeating: 0x41, count: 4 << 20), seconds: 2)
        }
        #expect(ContinuousClock.now - started < .seconds(8))
        await run.run.stop()
    }

    /// A cancelled delivery stops typing within about a second, even into a full pipe.
    @Test func aCancelledTypingStopsSoon() async throws {
        let run = try Self.standIn("echo ready\nexec sleep 30\n")
        defer { try? FileManager.default.removeItem(at: run.home) }
        _ = try await run.run.waitFor("ready", seconds: 10)
        let pty = run.run
        let typing = Task { try await pty.type(Data(repeating: 0x41, count: 1 << 20), seconds: 30) }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        typing.cancel()
        await #expect(throws: CloudMachineSecrets.DeliveryFailed(reason: "eof")) { try await typing.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        await run.run.stop()
    }

    /// Stopping waits for ssh to exit, and kills one that ignores the hang-up: none is left behind.
    @Test func aStopLeavesNoSSHBehindEvenOneThatIgnoresTerm() async throws {
        let run = try Self.standIn("trap '' TERM HUP\necho ready\nexec sleep 30\n")
        defer { try? FileManager.default.removeItem(at: run.home) }
        _ = try await run.run.waitFor("ready", seconds: 10)
        let started = ContinuousClock.now
        await run.run.stop()
        #expect(!run.run.isRunning)
        #expect(ContinuousClock.now - started < .seconds(8))
        await run.run.stop()
    }

    /// A stop from a cancelled task still ends an ssh that ignores the hang-up.
    @Test func aStopFromACancelledTaskStillEndsSSH() async throws {
        let run = try Self.standIn("trap '' TERM HUP\necho ready\nexec sleep 30\n")
        defer { try? FileManager.default.removeItem(at: run.home) }
        _ = try await run.run.waitFor("ready", seconds: 10)
        let pty = run.run
        let stopping = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await pty.stop()
        }
        await stopping.value
        #expect(!pty.isRunning)
    }

    // MARK: Helpers

    /// An ssh stand-in running `body` (stdin is the typing), started as the delivery starts one.
    static func standIn(_ body: String) throws -> (run: SSHPTYRun, home: URL) {
        let home = try scratchHome()
        let ssh = home.appendingPathComponent("ssh")
        try ("#!/bin/sh\n" + body).write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        return (try SSHPTYRun([ssh.path], environment: ["PATH": "/usr/bin:/bin"]), home)
    }

    static func scratchHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cn-ssh-secrets-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Stands in for ssh: the last argument is the remote command, run here; `-tt` gives it a pty.
    static func standInSSH(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("ssh")
        let script = """
            #!/bin/sh
            tty=no
            for arg; do [ "$arg" = "-tt" ] && tty=yes; last=$arg; done
            [ "$tty" = yes ] && exec /usr/bin/script -q /dev/null /bin/sh -c "$last"
            exec /bin/sh -c "$last"

            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func shell(_ script: String, home: URL) throws -> Int32 {
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func mode(_ url: URL) throws -> Int {
        try ((FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }
}
