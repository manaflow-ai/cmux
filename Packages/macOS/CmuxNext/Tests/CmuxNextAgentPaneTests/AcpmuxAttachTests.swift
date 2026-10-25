import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// DEV's `CMUX_NEXT_ACPMUX_ATTACH`: which builds attach to another app's daemon, and that an
/// attached host never starts, hands off or upgrades it.
@Suite(.serialized)
struct AcpmuxAttachTests {
    private static let user = URL(fileURLWithPath: "/Users/dev", isDirectory: true)
    private static let dev = BuildIdentity(bundleID: "com.cmuxterm.app.debug.attach", bundledTag: nil)

    private static func home(_ value: String?, build: BuildIdentity? = dev) -> String? {
        AcpmuxEnvironment.attachHome(build: build, environment: value.map { [AcpmuxEnvironment.attachKey: $0] } ?? [:],
                                     userHome: user)?.path
    }

    @Test func offUnlessSet() {
        #expect(Self.home(nil) == nil)
        #expect(Self.home("") == nil)
        #expect(Self.home("  ") == nil)
    }

    @Test func aDevBuildAttachesToAnAbsoluteOrTildeHome() {
        #expect(Self.home("/Users/dev/.acpmux") == "/Users/dev/.acpmux")
        #expect(Self.home("~/.acpmux/") == "/Users/dev/.acpmux")
        #expect(Self.home("~") == "/Users/dev")
    }

    @Test func aRelativePathIsIgnored() {
        #expect(Self.home(".acpmux") == nil)
        #expect(Self.home("~other/.acpmux") == nil)
    }

    @Test func onlyADevIdentityAttaches() {
        // NEXT DEV (a Release compile) and tagged DEV builds.
        for bundle in ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.next", "com.cmuxterm.app.debug.my-tag"] {
            #expect(Self.home("~/.acpmux", build: BuildIdentity(bundleID: bundle, bundledTag: nil)) == "/Users/dev/.acpmux", "\(bundle)")
        }
        for bundle in ["com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app",
                       "com.cmuxterm.app.rc", "com.cmuxterm.app.staging.x"] {
            #expect(Self.home("~/.acpmux", build: BuildIdentity(bundleID: bundle, bundledTag: nil)) == nil, "\(bundle) attached")
        }
        #expect(Self.home("~/.acpmux", build: nil) == nil)
    }

    @Test func attachedPointsAtThatDaemonsSocket() throws {
        let own = try #require(AcpmuxEnvironment.resolve(
            build: Self.dev, bundledBinDirectory: nil, environment: ["PATH": "/bin"], userHome: Self.user, uid: 501,
            isExecutable: { _ in true }, executableOverride: nil, teamIdentifier: nil))
        #expect(!own.isAttached)
        let attached = own.attached(to: URL(fileURLWithPath: "/Users/dev/.acpmux", isDirectory: true), uid: 501)
        #expect(attached.isAttached)
        #expect(attached.home.path == "/Users/dev/.acpmux")
        #expect(attached.socketPath == "/Users/dev/.acpmux/acpmux.sock")
        #expect(attached.childEnvironment["ACPMUX_HOME"] == "/Users/dev/.acpmux")
        #expect(attached.childEnvironment["ACPMUX_SOCKET"] == "/Users/dev/.acpmux/acpmux.sock")
        #expect(attached.daemonArguments.isEmpty)
    }

    /// A stand-in `acpmux` that records each launch; nothing listens on the attached socket.
    private static func fixture() throws -> (root: URL, environment: AcpmuxEnvironment) {
        let root = URL(fileURLWithPath: "/tmp/aat-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = bin.appendingPathComponent("acpmux")
        try "#!/bin/sh\ntouch '\(root.path)/launched'\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        let own = try #require(AcpmuxEnvironment.resolve(
            build: nil, bundledBinDirectory: bin, environment: ["ACPMUX_HOME": root.appendingPathComponent("own").path],
            executableOverride: nil, teamIdentifier: nil))
        // A crashed daemon's pid file: an owned host's reconnect would start one here.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        try "\(gone.processIdentifier)".write(to: home.appendingPathComponent("daemon.pid"), atomically: true, encoding: .utf8)
        return (root, own.attached(to: home))
    }

    @Test func anAttachedHostNeverStartsADaemon() async throws {
        let (root, environment) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = AcpmuxHost(resolve: { environment })

        await #expect(throws: AgentPaneHostError.daemonStopped) { _ = try await host.handshake(sessionId: nil) }
        await #expect(throws: AgentPaneHostError.daemonStopped) { _ = try await host.reconnectHandshake(sessionId: "s") }
        await #expect(throws: AgentPaneHostError.daemonStopped) { try await host.prewarm() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path),
                "an attached DEV build started a daemon in another app's home")
    }
}
