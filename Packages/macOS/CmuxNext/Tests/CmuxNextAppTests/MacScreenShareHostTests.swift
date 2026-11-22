@testable import CmuxNextMacScreen
import CmuxNextCompat
import Foundation
import Testing

/// Permission snapshots come from a fresh helper process; failed reads must not leave a prior grant
/// visible, and this app never reads or asks for a grant of its own.
@MainActor @Suite
struct MacScreenShareHostTests {
    /// A host whose helper is a stand-in bundle path (nothing is spawned: `readGrants` is replaced).
    static func hostWithHelper() -> MacScreenShareHost {
        let host = MacScreenShareHost()
        let helper = MacScreenHelper(app: URL(fileURLWithPath: "/nonexistent/cmux TEST Screen Sharing.app"))
        host.helper = { helper }
        return host
    }

    static func grants(_ screen: Bool, _ control: Bool) -> MacScreenHelper.Permissions {
        MacScreenHelper.Permissions(screenRecording: screen, accessibility: control)
    }

    @Test func aFreshReadReplacesCachedDenial() async {
        let host = Self.hostWithHelper()
        host.readGrants = { _ in Self.grants(false, false) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)

        host.readGrants = { _ in Self.grants(true, true) }
        await host.refreshPermissions()
        #expect(host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
    }

    @Test func aFailedProbeClearsAnEarlierGrant() async {
        let host = Self.hostWithHelper()
        host.readGrants = { _ in Self.grants(true, true) }
        await host.refreshPermissions()
        #expect(host.grantHolderName == "cmux TEST Screen Sharing")
        host.readGrants = { _ in nil }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        #expect(!host.accessibilityGranted)
    }

    @Test func aLaterReadWinsOverAnOlderOneThatEndsAfterIt() async {
        let host = Self.hostWithHelper()
        let (entered, enter) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        host.readGrants = { _ in
            enter.yield()
            var waiting = released.makeAsyncIterator()
            _ = await waiting.next()
            return Self.grants(true, true)
        }
        let older = Task { await host.refreshPermissions() }
        var waiting = entered.makeAsyncIterator()
        _ = await waiting.next()
        host.readGrants = { _ in Self.grants(false, true) }
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)
        release.yield()
        release.finish()
        await older.value
        #expect(!host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
    }

    /// A build without the Screen Sharing helper reads no grant at all (never this app's own),
    /// shows both off and names no holder.
    @Test func aBuildWithoutTheHelperShowsNoGrant() async {
        let host = MacScreenShareHost()
        host.helper = { nil }
        let reads = CmuxNextCompat.Atomic<Int>(0)
        host.readGrants = { _ in reads.wrappingAdd(1, ordering: .relaxed); return Self.grants(true, true) }

        await host.refreshPermissions()

        #expect(reads.load(ordering: .relaxed) == 0)
        #expect(!host.screenRecordingGranted)
        #expect(!host.accessibilityGranted)
        #expect(host.grantHolderName == nil)
    }

    /// A build without the helper asks macOS for nothing: no prompt names cmux, no Settings pane
    /// opens, and no wait for the person (Leo, 2026-11-22: no app restart to enable a grant).
    @Test(arguments: [true, false])
    func aBuildWithoutTheHelperAsksNothing(screenRecording: Bool) async {
        let host = MacScreenShareHost()
        host.helper = { nil }
        var opened = 0, settles = 0, waits = 0
        host.isAppActive = { true }
        host.openSettingsPane = { _ in opened += 1 }
        host.settle = { _ in settles += 1 }
        host.nextActivation = { waits += 1 }

        await host.requestAndWait(screenRecording: screenRecording)

        #expect(opened == 0 && settles == 0 && waits == 0)
        #expect(!host.screenRecordingGranted && !host.accessibilityGranted)
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
        let host = Self.hostWithHelper()
        var active = true
        var asked: [Bool] = [], opened: [Bool] = [], settles = 0, waits = 0
        host.readGrants = { _ in Self.grants(granted, false) }
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
        let host = Self.hostWithHelper()
        var waits = 0, settles = 0, opened = 0
        host.readGrants = { _ in Self.grants(false, false) }
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
