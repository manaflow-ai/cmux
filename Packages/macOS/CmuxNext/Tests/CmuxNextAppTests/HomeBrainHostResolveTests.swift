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
            let acpmux = dir.appendingPathComponent("acpmux")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: acpmux)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        }
        return dir
    }

    static let user = URL(fileURLWithPath: "/Users/someone")

    static func resolve(_ environment: [String: String], bin: URL?, tag: String = "hmchief", bundledChiefAllowed: Bool = true) -> HomeBrainHost? {
        HomeBrainHost.resolve(daemonSocket: "/tmp/d.sock", controlSocket: "/tmp/c.sock",
                              home: ChiefHome.resolve(tag: tag, environment: environment, userHome: user),
                              environment: environment, bundledBinDirectory: bin, bundledChiefAllowed: bundledChiefAllowed)
    }

    @Test func aBuildThatBundlesTheChiefStartsItWithoutAnyEnvironment() throws {
        let bin = try Self.binDirectory(withChief: true)
        let host = try #require(Self.resolve([:], bin: bin), "a bundled optchat-chief is the default brain host")
        #expect(host.executable.standardizedFileURL == bin.appendingPathComponent("optchat-chief").standardizedFileURL)
        #expect(host.muxHome.path == "/Users/someone/.cmux/chief/default")
        // The host's create request equals the app's (the owner refuses a different one under "home-chief").
        #expect(host.childEnvironment["MUX_USER_NAME"] == HomeChiefName.localUserName)
        #expect(host.childEnvironment["MUX_CHIEF_TITLE"] == HomeStrings.chiefName)
        #expect(host.arguments.suffix(5) == ["host", "--daemon-socket", "/tmp/d.sock", "--mux-home", "/Users/someone/.cmux/chief/default"])
    }

    /// The Chief's turns and subagents run on the Chief home's own acpmux, so
    /// a host started by another build finds the sessions its state names.
    @Test func everyBuildStartsTheSameHostOnTheChiefsOwnAcpmux() throws {
        let bin = try Self.binDirectory(withChief: true)
        let three = try #require(Self.resolve([:], bin: bin, tag: "hmchief3"))
        let four = try #require(Self.resolve([:], bin: bin, tag: "hmchief4"))
        #expect(three.arguments == four.arguments)
        #expect(three.childEnvironment["ACPMUX_HOME"] == "/Users/someone/.cmux/chief/default/acpmux")
        #expect(four.childEnvironment["ACPMUX_HOME"] == three.childEnvironment["ACPMUX_HOME"])
        #expect(three.childEnvironment["ACPMUX_SOCKET"] == four.childEnvironment["ACPMUX_SOCKET"])
    }

    /// The host outlives the app that started it: its cmux calls go through
    /// the Chief home's links to whichever app last opened Home, never to the
    /// starting app's own sockets (a stale one after it quit).
    @Test func theHostReachesTheRunningAppThroughConstantLinks() throws {
        let host = try #require(Self.resolve([:], bin: try Self.binDirectory(withChief: true)))
        #expect(host.childEnvironment["CMUX_SOCKET_PATH"] == "/Users/someone/.cmux/chief/default/state/app.sock")
        #expect(host.childEnvironment["CMUX_APP_DAEMON_SOCKET"] == "/Users/someone/.cmux/chief/default/state/app-daemon.sock")
        #expect(host.childEnvironment["CMUX_SOCKET_PATH"] != "/tmp/c.sock")
    }

    @Test func theLinksFollowTheLastAppAndAQuitRemovesOnlyItsOwn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chief-links-\(UUID().uuidString)", isDirectory: true)
        let home = ChiefHome(root: root, isolated: false)
        ChiefAppLinks.publish(home: home, controlSocket: "/tmp/a-control.sock", daemonSocket: "/tmp/a-daemon.sock")
        ChiefAppLinks.publish(home: home, controlSocket: "/tmp/b-control.sock", daemonSocket: "/tmp/b-daemon.sock")
        let fm = FileManager.default
        #expect(try fm.destinationOfSymbolicLink(atPath: ChiefAppLinks.controlLink(home).path) == "/tmp/b-control.sock")
        #expect(try fm.destinationOfSymbolicLink(atPath: ChiefAppLinks.daemonLink(home).path) == "/tmp/b-daemon.sock")
        ChiefAppLinks.unpublish(home: home, controlSocket: "/tmp/a-control.sock", daemonSocket: "/tmp/a-daemon.sock")
        #expect(try fm.destinationOfSymbolicLink(atPath: ChiefAppLinks.controlLink(home).path) == "/tmp/b-control.sock", "A quit; B keeps the Chief")
        ChiefAppLinks.unpublish(home: home, controlSocket: "/tmp/b-control.sock", daemonSocket: "/tmp/b-daemon.sock")
        #expect((try? fm.destinationOfSymbolicLink(atPath: ChiefAppLinks.controlLink(home).path)) == nil)
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
