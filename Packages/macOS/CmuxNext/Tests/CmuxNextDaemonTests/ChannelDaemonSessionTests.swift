import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A release and a nightly build on one Mac (cx-6so.41): the app launcher
/// gives each untagged channel its own daemon session and state, while
/// release keeps session `cmux-app` and cmux-tui's default state root, where
/// existing release state lives. It needs this tree's cmux-tui: an
/// installed or older one (the fallback when this tree's is not published)
/// refuses the launcher's flags.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct ChannelDaemonSessionTests {
    @Test func releaseAndNightlyRunSeparateDaemonsAtOnce() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-ch-\(id)")
        let support = root.appendingPathComponent("support")
        let runtime = root.appendingPathComponent("run")
        let defaultsSuite = "cnd-ch-\(id)"
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }

        // The app's own launcher for each channel's bundle id, with
        // Application Support and the remembered socket in this test's root.
        func appLauncher(_ bundleID: String) throws -> DaemonLauncher.Configuration {
            try DaemonLauncher.forApp(
                work: BackgroundWork(label: "test.daemon-launcher"),
                build: BuildIdentity(bundleID: bundleID, bundledTag: nil), installKeys: FrontendInstallKeyStores(team: { nil }),
                terminalEnvironment: [:],
                processEnvironment: [DaemonLauncher.binaryOverrideKey: binary.path],
                socketMemory: DaemonSocketMemory(defaults: { UserDefaults(suiteName: defaultsSuite) ?? .standard }),
                applicationSupport: support
            ).configuration
        }
        let release = try appLauncher("com.cmuxterm.app")
        let nightly = try appLauncher("com.cmuxterm.app.nightly")

        // Existing release state keeps working: same session, same root.
        #expect(release.session == "cmux-app")
        #expect(release.stateDirectory == nil)
        #expect(nightly.session == "cmux-app-nightly")
        #expect(nightly.stateDirectory == support.appendingPathComponent("cmux/tags/nightly/tui", isDirectory: true))

        // Run both at once. The test never uses the real runtime base or
        // the user's default state root: release's nil root (cmux-tui's
        // default) maps to one directory here, as both channels did before.
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh"]
        func isolated(_ configuration: DaemonLauncher.Configuration) throws -> DaemonLauncher {
            var configuration = configuration
            configuration.runtimeBase = runtime
            configuration.stateDirectory = configuration.stateDirectory ?? root.appendingPathComponent("default/sessions")
            try #require(configuration.stateDirectory?.path.hasPrefix(root.path + "/") == true)
            return DaemonLauncher(work: BackgroundWork(label: "test.daemon-launcher"), configuration: configuration, environment: { environment })
        }
        let releaseLauncher = try isolated(release)
        let nightlyLauncher = try isolated(nightly)
        let releaseConnection = DaemonConnection(configuration: BranchDaemonHarness.configuration(),
                                                 endpointProvider: releaseLauncher.endpointProvider)
        let nightlyConnection = DaemonConnection(configuration: BranchDaemonHarness.configuration(),
                                                 endpointProvider: nightlyLauncher.endpointProvider)
        // The daemons this test started (no terminals), stopped by pid when
        // a step fails before a connection knows them.
        var started: [Int32] = []
        do {
            let releaseEnsured = try await releaseLauncher.ensure()
            started.append(releaseEnsured.pid)
            let nightlyEnsured = try await nightlyLauncher.ensure()
            started.append(nightlyEnsured.pid)
            let releaseIdentity = try await releaseConnection.start()
            let nightlyIdentity = try await nightlyConnection.start()
            #expect(releaseIdentity.session == "cmux-app")
            #expect(nightlyIdentity.session == "cmux-app-nightly")
            #expect(releaseEnsured.socket != nightlyEnsured.socket)
            #expect(releaseIdentity.pid != nightlyIdentity.pid)
            #expect(kill(releaseIdentity.pid, 0) == 0 && kill(nightlyIdentity.pid, 0) == 0, "both daemons run at once")

            // State is separate: a release workspace never shows in nightly.
            _ = try await releaseConnection.createWorkspace(name: "release-only-\(id)")
            let releaseNames = try await releaseConnection.listWorkspaces().workspaces.map(\.name)
            let nightlyNames = try await nightlyConnection.listWorkspaces().workspaces.map(\.name)
            #expect(releaseNames.contains("release-only-\(id)"))
            #expect(!nightlyNames.contains("release-only-\(id)"))
        } catch {
            await BranchDaemonHarness.shutDown(nightlyConnection)
            await BranchDaemonHarness.shutDown(releaseConnection)
            for pid in Set(started) where kill(pid, 0) == 0 { kill(pid, SIGTERM) }
            throw error
        }
        await BranchDaemonHarness.shutDown(nightlyConnection)
        await BranchDaemonHarness.shutDown(releaseConnection)
    }
}
