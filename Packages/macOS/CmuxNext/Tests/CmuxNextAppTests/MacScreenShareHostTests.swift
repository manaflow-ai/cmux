import CmuxNextCompat
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import Dispatch
import Foundation
import Testing

/// Mac Screen's permission read (`MacScreenShareHost.refreshPermissions`): the Screen Recording and
/// Accessibility checks are synchronous TCC queries (blocking probe 2026-10-24: a dispatch_sync onto TCC's
/// preflight queue, 1.1 ms on the main thread at launch), so they run on the system lane; the main
/// thread only shows the answer, and the last read started decides.
@MainActor @Suite
struct MacScreenShareHostTests {
    @Test func theChecksRunOffTheMainThread() async {
        let threads = ThreadLog()
        let host = MacScreenShareHost(work: BackgroundWork())
        host.checkScreenRecording = { threads.note(); return true }
        host.checkAccessibility = { threads.note(); return true }

        await host.refreshPermissions()

        #expect(threads.onMain == [false, false])
        #expect(host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
    }

    /// An older read that ends after a newer one does not overwrite the newer answer.
    @Test func aLaterReadWinsOverAnOlderOneThatEndsAfterIt() async {
        let host = MacScreenShareHost(work: BackgroundWork())
        let gate = DispatchSemaphore(value: 0)
        let (entered, enter) = AsyncStream.makeStream(of: Void.self)
        let calls = Calls()
        host.checkAccessibility = { true }
        host.checkScreenRecording = {
            guard calls.next() == 0 else { return false }
            enter.yield()
            gate.wait()  // the lane thread holds the first read until the second one is shown
            return true
        }

        let older = Task { await host.refreshPermissions() }
        var waiting = entered.makeAsyncIterator()
        _ = await waiting.next()
        await host.refreshPermissions()
        #expect(!host.screenRecordingGranted)

        gate.signal()
        await older.value
        #expect(!host.screenRecordingGranted)
        #expect(host.accessibilityGranted)
    }

    /// A build without the Screen Sharing helper reads this app's own grants, and names no holder.
    @Test func aBuildWithoutTheHelperReadsTheAppsOwnGrants() async {
        let host = MacScreenShareHost(work: BackgroundWork())
        host.helper = { nil }
        host.checkScreenRecording = { true }
        host.checkAccessibility = { false }

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

/// Whether each check ran on the main thread, in call order.
private nonisolated final class ThreadLog: Sendable {
    private let calls = Mutex<[Bool]>([])
    func note() { calls.withLock { $0.append(Thread.isMainThread) } }
    var onMain: [Bool] { calls.withLock { $0 } }
}

/// Numbers the calls of a check from 0.
private nonisolated final class Calls: Sendable {
    private let count = Mutex(0)
    func next() -> Int {
        count.withLock { value in
            defer { value += 1 }
            return value
        }
    }
}
