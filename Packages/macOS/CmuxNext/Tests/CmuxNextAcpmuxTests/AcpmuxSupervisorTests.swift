import CmuxNextAcpmux
import Foundation
import Testing

struct AcpmuxSupervisorTests {
    @Test func eachBuildGetsItsOwnHomeAndSocket() throws {
        let support = URL(fileURLWithPath: "/tmp/support")
        let bin = try #require(ProcessInfo.processInfo.environment["ACPMUX_BIN"] ?? Optional("/bin/sh"))
        let env = ["CMUX_NEXT_ACPMUX_BIN": bin, "PATH": "/usr/bin"]
        let dev = try #require(AcpmuxLaunchConfiguration.forApp(tag: "agui", bundle: .main, processEnvironment: env, applicationSupport: support))
        let release = try #require(AcpmuxLaunchConfiguration.forApp(tag: nil, bundle: .main, processEnvironment: env, applicationSupport: support))
        #expect(dev.home.path == "/tmp/support/cmux/tags/agui/acpmux")
        #expect(release.home.path == "/tmp/support/cmux/acpmux")
        #expect(dev.socketPath != release.socketPath)
        #expect(dev.socketPath.utf8.count < 104, "sockaddr_un limit")
        #expect(dev.environment["ACPMUX_HOME"] == dev.home.path)
        #expect(dev.environment["ACPMUX_SOCKET"] == dev.socketPath)
        #expect(dev.environment["ACPMUX_LOGIN_ENV"] == "1")
        #expect(dev.environment["CMUX_NEXT_ACPMUX_BIN"] == nil)
        #expect(dev.arguments(parentPID: 42) == ["daemon", "run", "--exit-with-parent", "42", "--no-web"])
    }

    @Test func noBinaryMeansUnavailable() {
        #expect(AcpmuxLaunchConfiguration.forApp(tag: "x", bundle: .main, processEnvironment: [:], applicationSupport: URL(fileURLWithPath: "/tmp")) == nil)
    }

    /// With a real acpmux (ACPMUX_BIN): it runs, and comes back after it dies.
    @Test func runsAndRestartsTheDaemon() async throws {
        guard let bin = ProcessInfo.processInfo.environment["ACPMUX_BIN"] else { return }
        let home = URL(fileURLWithPath: "/tmp/cmux-acpmux-sup-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: home) }
        let socket = home.path + ".sock"
        let config = AcpmuxLaunchConfiguration(binary: URL(fileURLWithPath: bin), home: home, socketPath: socket,
                                               environment: ["HOME": home.path, "ACPMUX_HOME": home.path, "ACPMUX_SOCKET": socket, "ACPMUX_LOGIN_ENV": "0", "PATH": "/usr/bin:/bin"])
        let supervisor = AcpmuxSupervisor(configuration: config)
        var states = await supervisor.states().makeAsyncIterator()
        await supervisor.start()
        var firstPID: Int32?
        while let s = await states.next() {
            if case let .running(pid) = s { firstPID = pid; break }
        }
        let pid = try #require(firstPID)
        #expect(await supervisor.readySocketPath() == socket)
        kill(pid, SIGKILL)
        var restarted: Int32?
        while let s = await states.next() {
            if case let .running(p) = s { restarted = p; break }
        }
        #expect(restarted != nil && restarted != pid)
        await supervisor.stop()
        #expect(await supervisor.readySocketPath() == nil)
    }
}

