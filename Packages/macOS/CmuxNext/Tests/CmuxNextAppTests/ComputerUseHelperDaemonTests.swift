@testable import CmuxNextApp
import CmuxNextAgentActivity
import Darwin
import Foundation
import Testing

/// The app starts the signed cmux Computer Use helper only while Computer
/// Use is on: never an ad-hoc copy, token authorization only, the socket and
/// the agent token exported to children (never the host token), and the
/// helper stopped when Computer Use turns off or the app quits.
@MainActor
@Suite struct ComputerUseHelperDaemonTests {
    /// Records launches; like `cmux-cua serve`, listens on the `--socket` path.
    final class FakeLauncher: ComputerUseHelperLaunching {
        var launches: [(app: URL, arguments: [String], environment: [String: String])] = []
        var terminated: [pid_t] = []
        var listener: Int32 = -1

        func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> pid_t? {
            launches.append((app, arguments, environment))
            if let index = arguments.firstIndex(of: "--socket"), index + 1 < arguments.count {
                listener = ComputerUsePermissionSourceTests.bound(arguments[index + 1]) ?? -1
                if listener >= 0 { listen(listener, 4) }
            }
            return 4242
        }

        func terminate(_ pid: pid_t) {
            terminated.append(pid)
            if listener >= 0 { close(listener) }
            listener = -1
        }
    }

    nonisolated static let nightly = URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app/Contents/Library/cmux Computer Use.app")
    nonisolated static let adHoc = URL(fileURLWithPath: "/tmp/cmux DEV x.app/Contents/Library/cmux Computer Use.app")

    static func daemon(signed: Set<URL>, launcher: FakeLauncher, exported: @escaping (String, String?) -> Void)
        -> (ComputerUseHelperDaemon, String) {
        let id = UUID().uuidString.prefix(8)
        let socket = "/tmp/cu-d-\(id)/cua.sock"
        let state = FileManager.default.temporaryDirectory.appending(path: "cu-state-\(id)")
        let daemon = ComputerUseHelperDaemon(identity: CuaHelperIdentity { signed.contains($0) },
                                             candidates: { [adHoc, nightly] }, launcher: launcher,
                                             socketPath: socket, stateDirectory: state, exportEnvironment: exported)
        return (daemon, socket)
    }

    @Test func onStartsTheSignedHelperAndTheStepIsOffered() async throws {
        let launcher = FakeLauncher()
        var exported: [String: String] = [:]
        let (daemon, socket) = Self.daemon(signed: [Self.nightly], launcher: launcher) { key, value in exported[key] = value }
        defer { daemon.stop(); try? FileManager.default.removeItem(atPath: (socket as NSString).deletingLastPathComponent) }

        await daemon.apply(enabled: true)

        let launch = try #require(launcher.launches.first)
        #expect(launcher.launches.count == 1)
        #expect(launch.app == Self.nightly, "the NIGHTLY helper, never the ad-hoc copy")
        #expect(Array(launch.arguments.prefix(3)) == ["serve", "--socket", socket])
        let agent = try #require(launch.environment["CMUX_CUA_SOCKET_AUTH_TOKEN"])
        let host = try #require(launch.environment["CMUX_CUA_SOCKET_HOST_AUTH_TOKEN"])
        #expect(agent != host)
        #expect(!launch.environment.keys.contains { $0.hasPrefix("CMUX_CUA_SOCKET_AUTHORIZED_ROOT") }, "token authorization only")
        #expect(exported == ["CMUX_NEXT_CUA_SOCKET": socket, "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": agent], "never the host token")
        #expect(daemon.state == .running(4242))

        // Onboarding reads this helper, so the computer use step is offered.
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.onboarding.computerUseConfiguration = try #require(daemon.configuration)
        #expect(AppOnboardingServices(owner: services.onboarding).computerUsePermissions != nil)
    }

    @Test func offStartsNothing() async {
        let launcher = FakeLauncher()
        var exported: [String: String] = [:]
        let (daemon, _) = Self.daemon(signed: [Self.nightly], launcher: launcher) { key, value in exported[key] = value }
        await daemon.apply(enabled: false)
        #expect(launcher.launches.isEmpty)
        #expect(exported.isEmpty)
        #expect(daemon.state == .off)
    }

    @Test func withoutASignedHelperNothingStarts() async {
        let launcher = FakeLauncher()
        var exported: [String: String] = [:]
        let (daemon, _) = Self.daemon(signed: [], launcher: launcher) { key, value in exported[key] = value }
        await daemon.apply(enabled: true)
        #expect(launcher.launches.isEmpty, "an ad-hoc helper never starts")
        #expect(exported.isEmpty)
        #expect(daemon.state == .unavailable)
    }

    @Test func turningItOffOrQuittingStopsTheHelper() async {
        let launcher = FakeLauncher()
        var exported: [String: String] = [:]
        let (daemon, socket) = Self.daemon(signed: [Self.nightly], launcher: launcher) { key, value in exported[key] = value }
        defer { try? FileManager.default.removeItem(atPath: (socket as NSString).deletingLastPathComponent) }
        await daemon.apply(enabled: true)
        await daemon.apply(enabled: false)
        #expect(launcher.terminated == [4242])
        #expect(exported["CMUX_NEXT_CUA_SOCKET"] == nil && exported["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"] == nil)
        await daemon.apply(enabled: true)
        daemon.applicationWillTerminate()
        #expect(launcher.terminated == [4242, 4242])
        #expect(daemon.state == .off)
    }
}
