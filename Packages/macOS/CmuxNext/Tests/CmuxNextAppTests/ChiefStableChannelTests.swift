import Foundation
import Testing
import CmuxNextActions
@testable import CmuxNextHomeEngine

/// The classic → cmux-next handoff ships cmux-next as stable (`com.cmuxterm.app`), and release.yml
/// bundles the OptChat Chief there like nightly-next does. A build that ships the Chief starts it:
/// Home's Chief answers on stable and RC too. Developer tools stay DEV and NIGHTLY only.
struct ChiefStableChannelTests {
    private func bundledBin() throws -> URL {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-stable-\(UUID().uuidString)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let chief = bin.appendingPathComponent(HomeBrainHost.bundledChiefName)
        try "#!/bin/sh\n".write(to: chief, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chief.path)
        return bin
    }

    @Test(arguments: ["com.cmuxterm.app", "com.cmuxterm.app.rc", "com.cmuxterm.app.nightly"])
    func aReleaseBuildThatShipsTheChiefStartsIt(bundleID: String) throws {
        let allowed = HomeBrainHost.bundledChiefAllowed(bundleID: bundleID, isDebugBuild: false)
        #expect(HomeBrainHost.canStart(environment: [:], bundledBinDirectory: try bundledBin(), bundledChiefAllowed: allowed))
    }

    @Test func stableStillHasNoDeveloperTools() {
        #expect(!DevTools.isAvailable(bundleID: "com.cmuxterm.app", isDebugBuild: false))
        #expect(!DevTools.isAvailable(bundleID: "com.cmuxterm.app.rc", isDebugBuild: false))
    }

    @Test func anotherAppsBundleNeverStartsIt() {
        #expect(!HomeBrainHost.bundledChiefAllowed(bundleID: "com.example.other", isDebugBuild: false))
        #expect(!HomeBrainHost.bundledChiefAllowed(bundleID: nil, isDebugBuild: false))
    }
}
