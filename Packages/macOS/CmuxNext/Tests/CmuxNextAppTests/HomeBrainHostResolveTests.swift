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

    static func resolve(_ environment: [String: String], bin: URL?, tag: String = "hmchief") -> HomeBrainHost? {
        HomeBrainHost.resolve(daemonSocket: "/tmp/d.sock", controlSocket: "/tmp/c.sock",
                              home: ChiefHome.resolve(tag: tag, environment: environment, userHome: user),
                              environment: environment, bundledBinDirectory: bin)
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
}
