@testable import CmuxNextAgentActivity
import Foundation
import Testing

/// A build may use only a Developer ID signed "cmux Computer Use" helper.
/// An ad-hoc copy (what a tagged dev build makes) is refused, because a
/// Screen Recording grant to it replaces the release helper's TCC row.
@Suite struct CuaHelperIdentityTests {
    /// A helper bundle with the real bundle id, signed ad hoc like a tagged
    /// dev build signs it (identifier set, no certificate).
    static func adHocHelper(in directory: URL) throws -> URL {
        let app = directory.appending(path: CuaHelperIdentity.appName)
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appending(path: "cmux-cua"))
        let plist: [String: Any] = ["CFBundleIdentifier": CuaHelperIdentity.bundleIdentifier,
                                    "CFBundleExecutable": "cmux-cua", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", "--timestamp=none", "--identifier", CuaHelperIdentity.bundleIdentifier,
                              "--requirements", "=designated => identifier \"\(CuaHelperIdentity.bundleIdentifier)\"", app.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0, "codesign could not sign the test helper")
        return app
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cua-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func anAdHocHelperFailsTheSignatureCheck() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = try Self.adHocHelper(in: directory)
        #expect(!CuaHelperIdentity.satisfiesRequirement(helper))
        #expect(!CuaHelperIdentity.satisfiesRequirement(directory.appending(path: "missing.app")))
    }

    /// Fixture helpers in tests/fixtures/cua-helper-signatures: bundle id
    /// com.cmuxterm.cua, signed with an Apple Development and an Apple
    /// Distribution certificate of team 7WLXT3NR37. Both pass a team-only
    /// requirement, but their designated requirement is not the release
    /// helper's, so a grant to either replaces the release TCC row.
    static func signatureFixture(_ kind: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appending(path: "tests/fixtures/cua-helper-signatures/\(kind)/\(CuaHelperIdentity.appName)")
    }

    @Test(arguments: ["apple-development", "apple-distribution"])
    func aSameTeamSignatureThatIsNotDeveloperIDIsRefused(_ kind: String) throws {
        let helper = Self.signatureFixture(kind)
        try #require(FileManager.default.fileExists(atPath: helper.appending(path: "Contents/MacOS/cmux-cua").path),
                     "missing fixture \(helper.path)")
        #expect(!CuaHelperIdentity.satisfiesRequirement(helper))
        #expect(CuaHelperIdentity().resolve(running: nil, installed: [helper]) == .unavailable(.noSignedHelperInstalled))
    }

    /// The real check, end to end: a dev build whose only helper is an
    /// ad-hoc copy gets no helper, whether the copy runs or is only installed.
    @Test func anAdHocCandidateIsRefused() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = try Self.adHocHelper(in: directory)
        let identity = CuaHelperIdentity()
        #expect(identity.resolve(running: helper, installed: [helper]) == .unavailable(.runningHelperNotSigned(helper)))
        #expect(identity.resolve(running: nil, installed: [helper]) == .unavailable(.noSignedHelperInstalled))
        #expect(identity.resolve(running: nil, installed: []).helperURL == nil)
    }

    @Test func aSignedHelperIsUsed() {
        let signed = URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app/Contents/Library/cmux Computer Use.app")
        let adHoc = URL(fileURLWithPath: "/tmp/cmux DEV x.app/Contents/Library/cmux Computer Use.app")
        let identity = CuaHelperIdentity { $0 == signed }
        #expect(identity.resolve(running: nil, installed: [adHoc, signed]) == .signed(signed))
        #expect(identity.resolve(running: signed, installed: [adHoc]) == .signed(signed))
        // The running daemon needs the grant: an unsigned running copy is
        // not papered over by a signed copy elsewhere.
        #expect(identity.resolve(running: adHoc, installed: [signed]) == .unavailable(.runningHelperNotSigned(adHoc)))
    }

    /// A dev build's own helper is ad hoc: it tries NIGHTLY, then RC, then
    /// the release app (NIGHTLY's helper holds the grants on the team Macs).
    @Test func aDevBuildPrefersNightlyThenRCThenTheReleaseApp() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let dev = URL(fileURLWithPath: "/Users/someone/DerivedData/cmux DEV x.app")
        let paths = CuaHelperIdentity.installedCandidates(mainBundle: dev, home: home, isDevBuild: true).map(\.path)
        #expect(Array(paths.prefix(3)) == ["/Applications/cmux NIGHTLY.app/Contents/Library/cmux Computer Use.app",
                                           "/Applications/cmux RC.app/Contents/Library/cmux Computer Use.app",
                                           "/Applications/cmux.app/Contents/Library/cmux Computer Use.app"])
        #expect(!paths.contains { $0.hasPrefix(dev.path) }, "a dev build never uses its own ad-hoc helper")
        #expect(paths.allSatisfy { $0.hasPrefix("/Applications/") || $0.hasPrefix("/Users/someone/Applications/") })
        #expect(Set(paths).count == paths.count)
    }

    /// A release build uses the helper it ships (signed with it) first.
    @Test func aReleaseBuildUsesItsOwnHelperFirst() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let release = URL(fileURLWithPath: "/Applications/cmux NIGHTLY.app")
        let paths = CuaHelperIdentity.installedCandidates(mainBundle: release, home: home, isDevBuild: false).map(\.path)
        #expect(paths.first == "/Applications/cmux NIGHTLY.app/Contents/Library/cmux Computer Use.app")
        #expect(Set(paths).count == paths.count)
    }
}
