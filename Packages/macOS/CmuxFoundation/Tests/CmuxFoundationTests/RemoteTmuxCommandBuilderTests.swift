import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Remote tmux executable resolution")
struct RemoteTmuxCommandBuilderTests {
    @Test("remote argv resolves tmux and preserves every argument")
    func remoteCommandArgumentsExecute() throws {
        try withFakeTmux { directory, environment in
            let builder = RemoteTmuxCommandBuilder(arguments: [
                "new-session", "-A", "-s", "agent main", "quote'arg",
            ])
            let result = try run(
                executable: builder.remoteCommandArguments[0],
                arguments: Array(builder.remoteCommandArguments.dropFirst()),
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try capturedArguments(in: directory) == [
                "new-session", "-A", "-s", "agent main", "quote'arg",
            ])
        }
    }

    @Test("shell command preserves arguments through the outer login shell")
    func remoteShellCommandExecutes() throws {
        try withFakeTmux { directory, environment in
            let builder = RemoteTmuxCommandBuilder(arguments: [
                "new-session", "-A", "-s", "space and ' quote",
            ])
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", builder.remoteShellCommand],
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try capturedArguments(in: directory) == [
                "new-session", "-A", "-s", "space and ' quote",
            ])
        }
    }

    @Test("control-client command kills orphaned control clients before attaching")
    func controlClientCommandPrunesOrphanedControlClients() throws {
        let orphanedControlClient = try spawnOrphanedSleep()
        let orphanedPlainClient = try spawnOrphanedSleep()
        let parentedControlClient = try spawnChildSleep()
        defer {
            for pid in [orphanedControlClient, orphanedPlainClient, parentedControlClient.processIdentifier] {
                kill(pid, SIGKILL)
            }
        }
        try withFakeTmux(clients: [
            (pid: orphanedControlClient, controlMode: true),
            (pid: orphanedPlainClient, controlMode: false),
            (pid: parentedControlClient.processIdentifier, controlMode: true),
        ]) { directory, environment in
            let builder = RemoteTmuxCommandBuilder(
                arguments: ["-CC", "attach-session", "-t", "main"],
                prunesOrphanedControlClients: true
            )
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", builder.remoteShellCommand],
                environment: environment
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try capturedArguments(in: directory) == ["-CC", "attach-session", "-t", "main"])
            #expect(waitForExit(pid: orphanedControlClient))
            #expect(isAlive(pid: orphanedPlainClient))
            #expect(isAlive(pid: parentedControlClient.processIdentifier))
        }
    }

    @Test("one-shot command leaves orphaned control clients alone")
    func oneShotCommandDoesNotPruneClients() throws {
        let orphanedControlClient = try spawnOrphanedSleep()
        defer { kill(orphanedControlClient, SIGKILL) }
        try withFakeTmux(clients: [(pid: orphanedControlClient, controlMode: true)]) { directory, environment in
            let builder = RemoteTmuxCommandBuilder(arguments: ["list-sessions"])
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", builder.remoteShellCommand],
                environment: environment
            )

            #expect(result.status == 0)
            #expect(try capturedArguments(in: directory) == ["list-sessions"])
            #expect(isAlive(pid: orphanedControlClient))
        }
    }

    @Test("prune is skipped where sshd is PID 1")
    func pruneSkipsHostsWhereSSHDIsInit() throws {
        let orphanedControlClient = try spawnOrphanedSleep()
        defer { kill(orphanedControlClient, SIGKILL) }
        try withFakeTmux(clients: [(pid: orphanedControlClient, controlMode: true)], initCommand: "sshd") { _, environment in
            let builder = RemoteTmuxCommandBuilder(
                arguments: ["-CC", "attach-session", "-t", "main"],
                prunesOrphanedControlClients: true
            )
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", builder.remoteShellCommand],
                environment: environment
            )

            #expect(result.status == 0)
            #expect(isAlive(pid: orphanedControlClient))
        }
    }

    @Test("prune is skipped when PID 1 cannot be identified")
    func pruneSkipsHostsWhereInitLookupFails() throws {
        let orphanedControlClient = try spawnOrphanedSleep()
        defer { kill(orphanedControlClient, SIGKILL) }
        try withFakeTmux(clients: [(pid: orphanedControlClient, controlMode: true)], failsInitLookup: true) { directory, environment in
            let builder = RemoteTmuxCommandBuilder(
                arguments: ["-CC", "attach-session", "-t", "main"],
                prunesOrphanedControlClients: true
            )
            let result = try run(
                executable: "/bin/sh",
                arguments: ["-c", builder.remoteShellCommand],
                environment: environment
            )

            #expect(result.status == 0)
            #expect(try capturedArguments(in: directory) == ["-CC", "attach-session", "-t", "main"])
            #expect(isAlive(pid: orphanedControlClient))
        }
    }

    /// A `sleep` whose parent has exited, so the kernel reparents it to PID 1.
    private func spawnOrphanedSleep() throws -> pid_t {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 300 >/dev/null 2>&1 & echo $!"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(waitForParent(pid: pid, toBecome: 1))
        return pid
    }

    /// A `sleep` that stays a child of the test process.
    private func spawnChildSleep() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["300"]
        try process.run()
        return process
    }

    private func isAlive(pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func waitForExit(pid: pid_t, within seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isAlive(pid: pid) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func waitForParent(pid: pid_t, toBecome parent: pid_t, within seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            if sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, info.kp_eproc.e_ppid == parent {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Installs a fake `tmux` on PATH that answers `list-clients` with `clients` and
    /// records any other argv. `initCommand` is what a fake `ps` reports for PID 1;
    /// nil keeps the real `ps`. `failsInitLookup` makes only the PID 1 lookup fail
    /// with no output, as on a host with restricted `/proc`.
    private func withFakeTmux(
        clients: [(pid: pid_t, controlMode: Bool)],
        initCommand: String? = nil,
        failsInitLookup: Bool = false,
        operation: (URL, [String: String]) throws -> Void
    ) throws {
        let rows = clients.map { "\($0.pid):\($0.controlMode ? 1 : 0)" }.joined(separator: "\\n")
        try withFakeTmux(script: """
        #!/bin/sh
        if [ "$1" = list-clients ]; then printf '\(rows)\\n'; exit 0; fi
        printf '%s\\n' "$@" > "$TMUX_ARGS_FILE"
        """) { directory, environment in
            let initReply = failsInitLookup ? "exit 1" : initCommand.map { "echo \($0); exit 0" }
            if let initReply {
                let fakePS = directory.appending(path: "ps")
                try """
                #!/bin/sh
                if [ "$1" = -o ] && [ "$2" = comm= ] && [ "$4" = 1 ]; then \(initReply); fi
                exec /bin/ps "$@"
                """.write(to: fakePS, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePS.path)
            }
            try operation(directory, environment)
        }
    }

    private func withFakeTmux(
        script: String = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$TMUX_ARGS_FILE"
        """,
        operation: (URL, [String: String]) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-remote-tmux-builder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appending(path: "tmux")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try operation(directory, [
            "HOME": directory.path,
            "PATH": "\(directory.path):/usr/bin:/bin",
            "TMUX_ARGS_FILE": directory.appending(path: "tmux.args").path,
        ])
    }

    private func capturedArguments(in directory: URL) throws -> [String] {
        String(
            decoding: try Data(contentsOf: directory.appending(path: "tmux.args")),
            as: UTF8.self
        )
        .split(separator: "\n", omittingEmptySubsequences: false)
        .dropLast()
        .map(String.init)
    }

    private func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
