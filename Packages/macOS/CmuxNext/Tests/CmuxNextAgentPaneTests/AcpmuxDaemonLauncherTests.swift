import Darwin
import Foundation
import Synchronization
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
    /// suite left about 9, the app one per daemon start). The check names the launch shells
    /// themselves: a process-wide zombie count also saw other suites' children that were
    /// between their exit and their reap (hosted runs 37835676794, 37845131094, 37847351675).
    @Test func launchesLeaveNoZombieChildren() async throws {
        let (environment, root) = try environment(script: #"""
        printf '{"ready":true,"pid":%s,"webUrl":"http://127.0.0.1:5123/?token=tok"}\n' "$$" >&3
        """#)
        defer { try? FileManager.default.removeItem(at: root) }
        let shells = Mutex<[pid_t]>([])
        for _ in 0..<3 {
            _ = try await AcpmuxDaemonLauncher.launch(environment, deadline: .seconds(10),
                                                      onSpawn: { pid in shells.withLock { $0.append(pid) } })
        }
        let spawned = shells.withLock { $0 }
        #expect(spawned.count == 3)
        for pid in spawned {
            // Reaped means no longer our child: waitpid finds nothing to wait for.
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            let failure = errno
            #expect(result == -1 && failure == ECHILD,
                    "launch shell \(pid) is still our child after launch returned (waitpid \(result), errno \(failure))")
        }
    }
}
