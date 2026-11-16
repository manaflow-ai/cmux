import CmuxNextCompat
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The user: "all dev build environments must be isolated to those dev builds." Every process a dev build starts
/// that calls the cloud gets the build's space, and the build never routes into another build's Chief home or
/// registers the server agent that every build shares.
@Suite struct DevBuildProcessIsolationTests {
    static let space = ["CMUX_BUILD_SPACE": "dev:my-tag", "HOME": "/Users/me", "PATH": "/usr/bin"]

    /// `cmux link`'s hub pairing and heartbeats: its allow-listed environment keeps the build's space.
    @Test func theLinkGetsTheBuildsSpace() {
        let link = CloudLinkLauncher(binary: URL(fileURLWithPath: "/bin/cmux"), stateRoot: nil, tagged: true)
        #expect(link.environment(Self.space)["CMUX_BUILD_SPACE"] == "dev:my-tag")
        #expect(link.environment(["HOME": "/Users/me"])["CMUX_BUILD_SPACE"] == nil)
    }

    /// The Chief brain host (optchat-chief), its acpmux and subagents: the host's fresh environment keeps the space.
    @Test func theChiefBrainHostGetsTheBuildsSpace() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("brain-space-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in [HomeBrainHost.bundledChiefName, "acpmux"] {
            let file = bin.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let home = ChiefHome(root: base.appendingPathComponent("chief/com.cmuxterm.app.debug.my-tag", isDirectory: true), isolated: false,
                             buildID: "com.cmuxterm.app.debug.my-tag")
        let host = try #require(HomeBrainHost.resolve(daemonSocket: "/tmp/owner.sock", controlSocket: "/tmp/app.sock", home: home,
                                                      environment: [:], bundledBinDirectory: bin, bundledChiefAllowed: true))
        #expect(host.childEnvironment(process: Self.space)["CMUX_BUILD_SPACE"] == "dev:my-tag")
    }

    /// A dev build routes tabs only into its own Chief home; nightly never into a dev or staging build's home.
    @Test func chiefHomesAreAdmittedOnlyInTheirOwnSpace() {
        let root = URL(fileURLWithPath: "/Users/me/.cmux/chief", isDirectory: true)
        let dev = ChiefHome(root: root.appendingPathComponent("com.cmuxterm.app.debug.my-tag"), isolated: false)
        let nightly = ChiefHome(root: root.appendingPathComponent("default"), isolated: false)
        let devAdmits = ChiefHomeDirectory.admission(of: dev, devBuild: true)
        #expect(devAdmits(dev.root))
        #expect(!devAdmits(nightly.root))
        #expect(!devAdmits(root.appendingPathComponent("com.cmuxterm.app.debug.other")))
        let nightlyAdmits = ChiefHomeDirectory.admission(of: nightly, devBuild: false)
        #expect(nightlyAdmits(nightly.root))
        #expect(nightlyAdmits(root.appendingPathComponent("com.cmuxterm.app.nightly.cmux-next")))
        #expect(!nightlyAdmits(dev.root))
        #expect(!nightlyAdmits(root.appendingPathComponent("com.cmuxterm.app.debug.my-tag.work")))
        #expect(!nightlyAdmits(root.appendingPathComponent("com.cmuxterm.app.staging.my-tag")))
    }

    /// The server agent's `cmux host run` keeps one state for every build: a dev build refuses to register it.
    @MainActor @Test func aDevBuildNeverRegistersTheServerAgent() {
        var registered = false
        let agent = ServerLaunchAgent(isBundled: { true }, isDevBuild: { true }, allowRegister: { true },
                                      service: .init(status: { .notRegistered }, register: { registered = true }, openLoginItems: {}))
        #expect(throws: ServerLaunchAgent.Failure.devBuild) { try agent.register() }
        #expect(!registered)
    }
}
