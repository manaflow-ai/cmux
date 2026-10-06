import Foundation
import Testing
@testable import CmuxNextApp

/// Which brain host Home starts: `CMUX_NEXT_MUX_HOST` when it names an
/// executable, else the OptChat Chief bundled in Contents/Resources/bin. A
/// build without either starts nothing (Home works, the Chief does not answer).
/// hmdog had neither, so the Chief never replied.
@Suite struct HomeBrainHostResolveTests {
    static func binDirectory(withChief: Bool) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("home-brain-host-\(UUID().uuidString)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if withChief {
            let chief = dir.appendingPathComponent(HomeBrainHost.bundledChiefName)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: chief)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chief.path)
        }
        return dir
    }

    static func resolve(_ environment: [String: String], bin: URL?, bundledChiefAllowed: Bool = true) -> HomeBrainHost? {
        HomeBrainHost.resolve(daemonSocket: "/tmp/d.sock", controlSocket: "/tmp/c.sock", tag: "hmchief", environment: environment,
                              userHome: URL(fileURLWithPath: "/Users/someone"), bundledBinDirectory: bin,
                              bundledChiefAllowed: bundledChiefAllowed)
    }

    @Test func aBuildThatBundlesTheChiefStartsItWithoutAnyEnvironment() throws {
        let bin = try Self.binDirectory(withChief: true)
        let host = try #require(Self.resolve([:], bin: bin), "a bundled optchat-chief is the default brain host")
        #expect(host.executable.standardizedFileURL == bin.appendingPathComponent("optchat-chief").standardizedFileURL)
        #expect(host.muxHome.path == "/Users/someone/.cmux/mux/tags/hmchief")
        // The host's create request equals the app's (the owner refuses a different one under "home-chief").
        #expect(host.childEnvironment["MUX_USER_NAME"] == HomeChiefName.localUserName)
        #expect(host.childEnvironment["MUX_CHIEF_TITLE"] == HomeStrings.chiefName)
        #expect(host.arguments.suffix(5) == ["host", "--daemon-socket", "/tmp/d.sock", "--mux-home", "/Users/someone/.cmux/mux/tags/hmchief"])
    }

    @Test func theEnvironmentVariableStillOverridesTheBundledChief() throws {
        let bin = try Self.binDirectory(withChief: true)
        let host = try #require(Self.resolve(["CMUX_NEXT_MUX_HOST": "/bin/sh"], bin: bin))
        #expect(host.executable.path == "/bin/sh")
    }

    @Test func aBuildWithoutAHostStartsNothing() throws {
        #expect(Self.resolve([:], bin: try Self.binDirectory(withChief: false)) == nil)
        #expect(Self.resolve([:], bin: nil) == nil)
        // A variable naming something that cannot run falls back to the bundle, not to nothing.
        let bin = try Self.binDirectory(withChief: true)
        #expect(Self.resolve(["CMUX_NEXT_MUX_HOST": "/nonexistent/mux"], bin: bin)?.executable.lastPathComponent == "optchat-chief")
    }

    /// The bundled Chief runs on DEV and NIGHTLY only: a Release or RC
    /// bundle that carries one by mistake starts nothing, while an explicit
    /// CMUX_NEXT_MUX_HOST still runs.
    @Test func aReleaseOrRCBuildNeverStartsTheBundledChief() throws {
        let bin = try Self.binDirectory(withChief: true)
        #expect(Self.resolve([:], bin: bin, bundledChiefAllowed: false) == nil)
        #expect(Self.resolve(["CMUX_NEXT_MUX_HOST": "/bin/sh"], bin: bin, bundledChiefAllowed: false)?.executable.path == "/bin/sh")
        #expect(HomeBrainHost.bundledChiefAllowed(bundleID: "com.cmuxterm.app.nightly", isDebugBuild: false))
        #expect(HomeBrainHost.bundledChiefAllowed(bundleID: "com.cmuxterm.app.nightly.nxchief1", isDebugBuild: false))
        #expect(HomeBrainHost.bundledChiefAllowed(bundleID: "com.cmuxterm.app.debug.nxchief1", isDebugBuild: true))
        #expect(!HomeBrainHost.bundledChiefAllowed(bundleID: "com.cmuxterm.app", isDebugBuild: false))
        #expect(!HomeBrainHost.bundledChiefAllowed(bundleID: "com.cmuxterm.app.rc", isDebugBuild: false))
    }
}
