@testable import CmuxNextApp
import CmuxNextAgentActivity
import Darwin
import Foundation
import Testing

/// cx-vn9q: the helper starts through LaunchServices, so its parent is
/// launchd and an app crash left it running. A helper whose `cmux-cua
/// manifest` lists `serve.owner-pid` gets `--owner-pid <this app's pid>` and
/// exits with this app. An older helper may reject an unknown flag, so it
/// never gets it; a manifest that fails or hangs counts as an older helper.
@MainActor
@Suite(.serialized) struct ComputerUseHelperOwnerPIDTests {
    /// A fake helper app: `Contents/MacOS/cmux-cua` is a shell script that
    /// answers `manifest` with `body` and counts its runs in `runs`.
    struct FakeHelper {
        let root: URL
        let app: URL
        let runs: URL

        init(manifest body: String) throws {
            root = URL(fileURLWithPath: "/tmp/cu-op-\(UUID().uuidString.prefix(8))")
            app = root.appending(path: "cmux Computer Use.app")
            runs = root.appending(path: "runs")
            let macOS = app.appending(path: "Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleExecutable": "cmux-cua", "CFBundleIdentifier": "com.cmuxterm.cua",
                                        "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: app.appending(path: "Contents/Info.plist"))
            let script = macOS.appending(path: "cmux-cua")
            try "#!/bin/sh\necho run >> '\(runs.path)'\n[ \"$1\" = manifest ] || exit 64\n\(body)\n"
                .write(to: script, atomically: true, encoding: .utf8)
            chmod(script.path, 0o755)
        }

        var runCount: Int {
            ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static let capable = #"echo '{"schema_version":"1","capabilities":["serve.owner-pid","other"],"subcommands":[]}'"#
    static let old = #"echo '{"schema_version":"1","binary_version":"0.7.1","subcommands":[]}'"#

    static func start(_ helper: FakeHelper, reader: CuaHelperManifestReader = CuaHelperManifestReader())
        async -> (ComputerUseHelperDaemonTests.FakeLauncher, [String]) {
        let launcher = ComputerUseHelperDaemonTests.FakeLauncher()
        let id = UUID().uuidString.prefix(8)
        let daemon = ComputerUseHelperDaemon(identity: CuaHelperIdentity { $0 == helper.app }, candidates: { [helper.app] },
                                             launcher: launcher, manifestReader: reader,
                                             socketPath: "/tmp/cu-op-s-\(id)/s/cua.sock",
                                             stateDirectory: FileManager.default.temporaryDirectory.appending(path: "cu-op-st-\(id)"))
        await daemon.apply(enabled: true)
        daemon.stop()
        try? FileManager.default.removeItem(atPath: "/tmp/cu-op-s-\(id)")
        return (launcher, launcher.launches.first?.arguments ?? [])
    }

    @Test func aHelperThatListsTheCapabilityGetsThisAppsPID() async throws {
        let helper = try FakeHelper(manifest: Self.capable)
        defer { helper.remove() }
        let (launcher, arguments) = await Self.start(helper)
        #expect(launcher.launches.count == 1)
        let index = try #require(arguments.firstIndex(of: "--owner-pid"), "\(arguments)")
        #expect(arguments[index + 1] == String(getpid()))
        #expect(arguments.filter { $0 == "--owner-pid" }.count == 1)
    }

    @Test func anOlderHelperGetsNoFlag() async throws {
        let helper = try FakeHelper(manifest: Self.old)
        defer { helper.remove() }
        let (launcher, arguments) = await Self.start(helper)
        #expect(launcher.launches.count == 1, "an older helper still starts")
        #expect(!arguments.contains("--owner-pid"), "\(arguments)")
        #expect(Array(arguments.prefix(2)) == ["serve", "--socket"])
    }

    @Test func aFailingManifestStartsWithoutTheFlag() async throws {
        let helper = try FakeHelper(manifest: "echo 'unknown subcommand' >&2; exit 2")
        defer { helper.remove() }
        let (launcher, arguments) = await Self.start(helper)
        #expect(launcher.launches.count == 1)
        #expect(!arguments.contains("--owner-pid"))
    }

    @Test func aManifestThatIsNotJSONStartsWithoutTheFlag() async throws {
        let helper = try FakeHelper(manifest: "echo 'serve.owner-pid'")
        defer { helper.remove() }
        let (_, arguments) = await Self.start(helper)
        #expect(!arguments.contains("--owner-pid"))
    }

    /// A hung manifest is stopped at the bound; the helper starts without the flag.
    @Test func aHangingManifestStartsWithoutTheFlagWithinTheBound() async throws {
        let helper = try FakeHelper(manifest: "exec /bin/sleep 30")
        defer { helper.remove() }
        let reader = CuaHelperManifestReader(timeout: .milliseconds(300), clock: ContinuousClock())
        let started = ContinuousClock.now
        let (launcher, arguments) = await Self.start(helper, reader: reader)
        #expect(ContinuousClock.now - started < .seconds(5), "the start waited for the hung manifest")
        #expect(launcher.launches.count == 1)
        #expect(!arguments.contains("--owner-pid"))
    }

    /// A manifest whose child keeps its output open after the kill still
    /// ends at the bound (the reader drains on its own).
    @Test func aManifestWhoseChildHoldsTheOutputStillEndsAtTheBound() async throws {
        let helper = try FakeHelper(manifest: "/bin/sleep 8")
        defer { helper.remove() }
        let reader = CuaHelperManifestReader(timeout: .milliseconds(300), clock: ContinuousClock())
        let started = ContinuousClock.now
        #expect(await reader.capabilities(of: helper.app).isEmpty)
        #expect(ContinuousClock.now - started < .seconds(4), "the read waited for the grandchild")
    }

    /// A cancelled read returns at once with no capability.
    @Test func aCancelledReadReturnsNoCapability() async throws {
        let helper = try FakeHelper(manifest: "exec /bin/sleep 30")
        defer { helper.remove() }
        let reader = CuaHelperManifestReader(timeout: .seconds(60), clock: ContinuousClock())
        let started = ContinuousClock.now
        let read = Task { await reader.capabilities(of: helper.app) }
        while helper.runCount == 0 { await Task.yield() }
        read.cancel()
        #expect(await read.value.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    /// The manifest runs once per helper binary; a changed binary is read again.
    @Test func theManifestIsReadOncePerHelperBinary() async throws {
        let helper = try FakeHelper(manifest: Self.capable)
        defer { helper.remove() }
        let reader = CuaHelperManifestReader()
        #expect(await reader.capabilities(of: helper.app).contains("serve.owner-pid"))
        #expect(await reader.capabilities(of: helper.app).contains("serve.owner-pid"))
        #expect(helper.runCount == 1)

        // A new helper version at the same path (a new modification date).
        let script = helper.app.appending(path: "Contents/MacOS/cmux-cua")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: script.path)
        _ = await reader.capabilities(of: helper.app)
        #expect(helper.runCount == 2)
    }

    /// The manifest read does not write this process's environment
    /// (libghostty keeps a slice of `environ`), and argv carries no token.
    @Test func theOwnerPIDPathNeverWritesTheEnvironmentNorPutsATokenInArgv() async throws {
        let helper = try FakeHelper(manifest: Self.capable)
        defer { helper.remove() }
        let before = ComputerUseEnvironmentSafetyTests.EnvironSnapshot.take()
        let (launcher, arguments) = await Self.start(helper)
        #expect(ComputerUseEnvironmentSafetyTests.EnvironSnapshot.take() == before)
        let launch = try #require(launcher.launches.first)
        for key in ["CMUX_CUA_SOCKET_AUTH_TOKEN", "CMUX_CUA_SOCKET_HOST_AUTH_TOKEN"] {
            let token = try #require(launch.environment[key])
            #expect(!arguments.contains { $0.contains(token) }, "\(key) is in argv")
        }
    }
}
