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

    /// One prompt at a time (Lawrence, 2026-11-17: macOS's prompt and our Check Again sheet were up
    /// at once). A request that did not grant waits while macOS's prompt has focus, and opens the
    /// Settings pane only when nothing took focus (macOS asks once per grant).
    @Test(arguments: [(true, true), (true, false), (false, true), (false, false)])
    func aRequestWaitsForMacOSsOwnSurface(granted: Bool, promptTakesFocus: Bool) async {
        let host = MacScreenShareHost()
        var active = true
        var asked: [Bool] = [], opened: [Bool] = [], settles = 0, waits = 0
        host.helper = { nil }
        host.readPermissions = { (granted, false) }
        host.isAppActive = { active }
        host.askMacOS = { asked.append($0); return granted }
        host.settle = { _ in settles += 1; if promptTakesFocus { active = false } }
        host.nextActivation = { waits += 1; active = true }
        host.openSettingsPane = { opened.append($0) }

        await host.requestAndWait(screenRecording: true)

        #expect(asked == [true])
        #expect(host.screenRecordingGranted == granted)
        if granted {
            #expect(opened.isEmpty && settles == 0 && waits == 0)
        } else if promptTakesFocus {
            #expect(opened.isEmpty && settles == 1 && waits == 1)
        } else {
            #expect(opened == [true] && settles == 1 && waits == 0)
        }
    }

    /// A request started while this app is already in the background waits for the person's return.
    @Test func aRequestFromTheBackgroundWaitsForTheReturn() async {
        let host = MacScreenShareHost()
        var waits = 0, settles = 0, opened = 0
        host.helper = { nil }
        host.readPermissions = { (false, false) }
        host.isAppActive = { waits == 0 ? false : true }
        host.askMacOS = { _ in false }
        host.settle = { _ in settles += 1 }
        host.nextActivation = { waits += 1 }
        host.openSettingsPane = { _ in opened += 1 }

        await host.requestAndWait(screenRecording: false)
        #expect(waits == 1 && settles == 0 && opened == 0)
    }

    /// The helper's one JSON line (cmux-rd-host src/permissions.rs).
    @Test func theHelpersAnswerDecodes() throws {
        let answer = try JSONDecoder().decode(MacScreenHelper.Permissions.self,
                                              from: Data(#"{"screen_recording":true,"accessibility":false}"#.utf8))
        #expect(answer == MacScreenHelper.Permissions(screenRecording: true, accessibility: false))
    }
}
