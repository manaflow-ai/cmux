@testable import CmuxNextMacScreen
import Foundation
import Testing

/// Permission snapshots use a fresh child; failed reads must not leave a prior grant visible.
@MainActor @Suite
struct MacScreenShareHostTests {
    @Test func aFreshReadReplacesCachedDenial() async {
        let host = MacScreenShareHost()
        host.readPermissions = { (false, false) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)

        host.readPermissions = { (true, true) }
        await host.refreshPermissions()
        #expect(host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
    }

    @Test func aFailedProbeClearsAnEarlierGrant() async {
        let host = MacScreenShareHost()
        host.readPermissions = { (true, true) }
        await host.refreshPermissions()
        host.readPermissions = { throw CocoaError(.fileNoSuchFile) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        #expect(!host.accessibilityGranted)
    }

    @Test func aLaterReadWinsOverAnOlderOneThatEndsAfterIt() async {
        let host = MacScreenShareHost()
        let (entered, enter) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        host.readPermissions = {
            enter.yield()
            var waiting = released.makeAsyncIterator()
            _ = await waiting.next()
            return (true, true)
        }
        let older = Task { await host.refreshPermissions() }
        var waiting = entered.makeAsyncIterator()
        _ = await waiting.next()
        host.readPermissions = { (false, true) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        release.yield()
        release.finish()
        await older.value
        #expect(!host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
    }

    /// A build without the Screen Sharing helper reads this app's own grants, and names no holder.
    @Test func aBuildWithoutTheHelperReadsTheAppsOwnGrants() async {
        let host = MacScreenShareHost()
        host.helper = { nil }
        host.readPermissions = { (true, false) }

        await host.refreshPermissions()

        #expect(host.screenRecordingGranted)
        #expect(!host.accessibilityGranted)
        #expect(host.grantHolderName == nil)
    }

    /// The helper is the one `* Screen Sharing.app` in Contents/Library with its executable;
    /// a bundle without one has no helper.
    @Test func theHelperIsFoundInTheAppsLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mac-screen-helper-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "cmux TEST.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/Library/Other.app"), withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: app))
        #expect(MacScreenHelper.bundled(bundle) == nil)

        let helper = app.appending(path: "Contents/Library/cmux TEST Screen Sharing.app", directoryHint: .isDirectory)
        let executable = helper.appending(path: "Contents/MacOS/\(MacScreenHelper.executableName)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
        let found = try #require(MacScreenHelper.bundled(bundle))
        #expect(found.name == "cmux TEST Screen Sharing")
        #expect(found.app.standardizedFileURL == helper.standardizedFileURL)
    }

    /// The helper's one JSON line (cmux-rd-host src/permissions.rs).
    @Test func theHelpersAnswerDecodes() throws {
        let answer = try JSONDecoder().decode(MacScreenHelper.Permissions.self,
                                              from: Data(#"{"screen_recording":true,"accessibility":false}"#.utf8))
        #expect(answer == MacScreenHelper.Permissions(screenRecording: true, accessibility: false))
    }
}
