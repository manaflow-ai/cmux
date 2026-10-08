import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Runs the real spawn path against a stand-in `acpmux` script.
@Suite struct AcpmuxDaemonLauncherTests {
    private func environment(script: String) throws -> (AcpmuxEnvironment, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("acpmux")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let socket = root.appendingPathComponent("a.sock").path
        return (AcpmuxEnvironment(executable: executable, home: home, socketPath: socket, daemonArguments: ["--listen", "127.0.0.1:0"],
                                  childEnvironment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket]), root)
    }

    @Test func readsTheEndpointFromTheReadyLine() async throws {
        // Echoes its arguments to the log and reports ready on fd 3.
        let (environment, root) = try environment(script: #"""
        echo "login=$ACPMUX_LOGIN_ENV $@"
        printf '{"ready":true,"pid":%s,"webUrl":"http://127.0.0.1:5123/?token=tok"}\n' "$$" >&3
        """#)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10))
        #expect(endpoint == AcpmuxWebEndpoint(url: URL(string: "ws://127.0.0.1:5123/")!, token: "tok"))
        let log = try String(contentsOfFile: environment.logPath, encoding: .utf8)
        #expect(log.contains("login=1 daemon run --ready-fd 3 --listen 127.0.0.1:0"))
    }

    @Test func onlyTheReadyDescriptorReachesTheDaemon() async throws {
        var (environment, root) = try environment(script: #"""
        for fd in $(seq 3 20); do
            if [ -e "/dev/fd/$fd" ]; then printf '%s ' "$fd" >> "$ACPMUX_FDS_LOG"; fi
        done
        printf '\n' >> "$ACPMUX_FDS_LOG"
        printf '{"ready":true,"pid":%s,"webUrl":"http://127.0.0.1:5123/?token=tok"}\n' "$$" >&3
        """#)
        defer { try? FileManager.default.removeItem(at: root) }

        let inheritedPath = root.appendingPathComponent("inherited-fds")
        environment.childEnvironment["ACPMUX_FDS_LOG"] = inheritedPath.path
        let lockPath = root.appendingPathComponent("host.lock")
        let lock = lockPath.path.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
        #expect(lock >= 0)
        defer { if lock >= 0 { Darwin.close(lock) } }
        let inherited = fcntl(lock, F_DUPFD, 9)
        #expect(inherited >= 0)
        defer { if inherited >= 0 { Darwin.close(inherited) } }

        _ = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10))
        let descriptors = try String(contentsOf: inheritedPath, encoding: .utf8)
        #expect(descriptors == "3 \n")
    }

    @Test func aDaemonThatExitsEarlyIsReportedWithItsLog() async throws {
        let (environment, root) = try environment(script: "echo 'error: address in use' >&2\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: AcpmuxDaemonLauncher.Failure.exited(logPath: environment.logPath)) {
            try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10))
        }
        #expect(try String(contentsOfFile: environment.logPath, encoding: .utf8).contains("address in use"))
    }

    @Test func aReadyLineWithoutAWebSocketIsAFailure() async throws {
        let (environment, root) = try environment(script: #"printf '{"ready":true}\n' >&3"# + "\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: AcpmuxDaemonLauncher.Failure.noWebSocket(logPath: environment.logPath)) {
            try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10))
        }
    }

    @Test func aSilentDaemonMissesTheDeadline() async throws {
        let (environment, root) = try environment(script: "sleep 2\n")
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: AgentPaneDeadlineExceeded.self) {
            try await AcpmuxDaemonLauncher.launch(environment, deadline: .milliseconds(300))
        }
    }

    /// cx-9dh7: the daemon's agents reach the app's Computer Use helper
    /// through the daemon's spawn environment (the app never writes its
    /// own): the socket and the agent token, never the host token.
    @Test func theSpawnEnvironmentCarriesTheComputerUseSocketAndAgentTokenOnly() async throws {
        var (environment, root) = try environment(script: #"""
        echo "socket=${CMUX_NEXT_CUA_SOCKET-unset} agent=${CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN-unset} host=${CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN-unset}"
        printf '{"ready":true,"pid":%s,"webUrl":"http://127.0.0.1:5123/?token=tok"}\n' "$$" >&3
        """#)
        defer { try? FileManager.default.removeItem(at: root) }
        environment.computerUse = ["CMUX_NEXT_CUA_SOCKET": "/tmp/cu/cua.sock", "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": "agent-tok",
                                   "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN": "host-tok"]
        _ = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10))
        let log = try String(contentsOfFile: environment.logPath, encoding: .utf8)
        #expect(log.contains("socket=/tmp/cu/cua.sock agent=agent-tok host=unset"), "\(log)")
    }

    /// Computer Use off: no Computer Use variable reaches the daemon, not
    /// even one inherited at launch; the host token never does.
    @Test func withComputerUseOffNoComputerUseVariableReachesTheDaemon() throws {
        let (environment, root) = try environment(script: "")
        defer { try? FileManager.default.removeItem(at: root) }
        let inherited = ["PATH": "/usr/bin", "CMUX_NEXT_CUA_SOCKET": "/tmp/launch.sock",
                         "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": "launch-agent", "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN": "launch-host"]
        let off = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: inherited)
        #expect(off["PATH"] == "/usr/bin")
        #expect(off.keys.filter { $0.hasPrefix("CMUX_NEXT_CUA") }.isEmpty, "\(off)")
        var on = environment
        on.computerUse = ["CMUX_NEXT_CUA_SOCKET": "/tmp/cu.sock", "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": "agent",
                          "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN": "host"]
        let spawned = AcpmuxDaemonLauncher.spawnEnvironment(on, inherited: inherited)
        #expect(spawned["CMUX_NEXT_CUA_SOCKET"] == "/tmp/cu.sock")
        #expect(spawned["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"] == "agent")
        #expect(spawned["CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN"] == nil)
    }

    /// cx-xqng: the throwaway launch shell exits as soon as it backgrounds the daemon; the
    /// launcher reaps it, so launches leave no zombie children in this process (the AgentPane
    /// suite left about 9, the app one per daemon start).
    @Test func launchesLeaveNoZombieChildren() async throws {
        let (environment, root) = try environment(script: #"""
        printf '{"ready":true,"pid":%s,"webUrl":"http://127.0.0.1:5123/?token=tok"}\n' "$$" >&3
        """#)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = ZombieChildren.count()
        for _ in 0..<3 { _ = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10)) }
        let after = ZombieChildren.count()
        // Other suites run in parallel and may hold a child for a moment; three launches
        // that each leak a shell add three zombies that never go away.
        #expect(after - before < 3, "zombie children before \(before), after \(after)")
    }
}

/// This process's children that exited and were not reaped (`SZOMB`).
enum ZombieChildren {
    static func count() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return -1 }
        size += size / 4
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return -1 }
        let me = getpid()
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .filter { $0.kp_eproc.e_ppid == me && $0.kp_proc.p_stat == SZOMB }.count
    }
}
