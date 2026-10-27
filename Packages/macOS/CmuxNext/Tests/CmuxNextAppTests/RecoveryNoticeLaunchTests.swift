import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The recovered-drafts notice at launch (p08-startup-081, Q11): one afterFirstFrame post that reads the drafts on
/// the files lane and replies to main. No read and no toast before the first window's first frame; the toast after it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct RecoveryNoticeLaunchTests {
    /// Counts the shown toast views (the center's overlay host, without an overlay).
    @MainActor private final class RecordingHost: CmuxToastHosting {
        private(set) var count = 0

        func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {
            count += 1
        }
        func move(_ toast: CmuxToastView, to slot: Int) {}
        func hide(_ toast: CmuxToastView, animated: Bool) {}
    }

    @Test func theNoticeRunsOnlyAfterTheFirstFrame() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "recovery-notice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryDraftStore(directory: directory)
        let id = QuitParticipantID.file(path: "/tmp/recovery-notice-launch/notes.md")
        #expect(store.update(id: id, title: "notes.md", contents: Data("unsaved".utf8)) == .kept)
        await store.writePending()
        let host = RecordingHost()
        let toasts = CmuxToastCenter(host: host)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let f = LaunchOrderFixture()

        RecoveryNotice.post(store: store, toasts: toasts, in: window, on: f.order.startup, work: f.background,
                            mainWork: f.scheduler.mainWork)
        f.hand.drain()
        for _ in 0..<3 { f.fire() }
        let record = { f.order.startup.log.records.first { $0.name.description == "RecoveryNotice.read" } }
        #expect(record()?.priority == .afterFirstFrame)
        #expect(record()?.destination == .main)
        #expect(record()?.durationNanos == nil, "the post waits for the first frame")
        spinUntil(f, for: 0.2) { false }
        #expect(host.count == 0, "no read and no toast before the first frame")

        f.order.startup.firstFrameCommitted()
        for _ in 0..<3 { f.fire() }
        #expect(record()?.durationNanos != nil, "the post ran after the first frame, before startup completes")
        spinUntil(f) { host.count > 0 }
        #expect(toasts.toasts(in: window).map(\.id) == ["recovery:\(id)"], "the files lane's read replied with one toast per draft")
    }

    /// Main run loop passes (the reply's hop) and frames (its visible class) until `done` or `seconds`.
    private func spinUntil(_ f: LaunchOrderFixture, for seconds: TimeInterval = 5, _ done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            f.fire()
        }
    }
}
