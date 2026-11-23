#if os(iOS)
import CmuxMobileArtifacts
import Foundation
import QuartzCore
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-14: "this is just such a f***ing hog of CPU and f***ing
/// battery and f***ing RAM as well". Up to `GhosttyTerminalTabContent.warmLimit`
/// warm tabs stay attached and keep receiving their Mac's output. A tab out of
/// its window drew nothing (`TerminalSurfaceOcclusionTests`), but its screen
/// still ran a display link at the terminal's 80-120 Hz for as long as output
/// came, handed Ghostty one batch per frame, scanned each batch on the main
/// thread and asked the renderer for a frame after each one.
///
/// A page nobody can see now feeds its output with no display link, in one
/// coalesced batch per `TerminalViewController.hiddenFeedInterval`, and asks
/// for no frames; shown again, everything queued goes to Ghostty at once.
/// Nothing is dropped: the page shows the last line written while hidden.
///
/// Through the real screen (`TerminalViewController`) and Ghostty surface.
/// The numbers it prints are the before/after harness of the change.
@MainActor
@Suite(.serialized) struct TerminalHiddenOutputPacingTests {
    /// A Mac terminal that writes what the test says, when it says.
    @MainActor
    final class ScriptedSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        /// Every `setOutputPaused` call, in order.
        private(set) var pauses: [Bool] = []
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
        func setOutputPaused(_ paused: Bool) { pauses.append(paused) }
        func write(_ data: Data) { handler?(.output(data)) }
    }

    /// A screen in a window, its surface made, then taken out of the window
    /// the way a warm tab behind another is.
    struct Rig {
        let window: UIWindow
        let session: ScriptedSession
        let screen: TerminalViewController

        func hide() { screen.view.removeFromSuperview() }
        func show() {
            screen.view.frame = window.bounds
            window.rootViewController?.view.addSubview(screen.view)
        }
    }

    static func rig() async throws -> Rig {
        let session = ScriptedSession()
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "hidden")
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        root.addChild(screen)
        screen.view.frame = window.bounds
        root.view.addSubview(screen.view)
        screen.didMove(toParent: root)
        window.makeKeyAndVisible()
        try await waitUntil(5) { session.handler != nil && screen.surface.surface != nil }
        try #require(session.handler != nil, "the screen never started its session")
        try #require(screen.surface.surface != nil, "libghostty created no surface")
        session.write(Data("ready\r\n".utf8))
        try await waitUntil(3) { screen.surface.screenText()?.contains("ready") == true }
        return Rig(window: window, session: session, screen: screen)
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls the screen until a deadline
        }
    }

    /// `count` numbered lines of about 64 bytes, from `start`.
    static func lines(_ tag: String, from start: Int, count: Int) -> Data {
        Data((start..<start + count).map { "\(tag) \($0) " + String(repeating: "x", count: 48) + "\r\n" }.joined().utf8)
    }

    /// A hidden tab with a build log running in it: 2 s of ~200 KB/s output
    /// (32 lines every 10 ms, the rate of a busy compile).
    @Test func aHiddenPageFeedsItsOutputWithNoDisplayLinkAndShowsAllOfItAtOnce() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.rig()
        defer { rig.window.isHidden = true }
        rig.hide()
        try await Task.sleep(for: .milliseconds(200)) // test: the reveal's own work settles
        let before = rig.screen.outputCounts
        let drawsBefore = rig.screen.surface.drawRequests

        let duration = 2.0
        let start = ContinuousClock.now
        var written = 0
        var bytes = 0
        while ContinuousClock.now < start.advanced(by: .milliseconds(Int(duration * 1000))) {
            let chunk = Self.lines("log", from: written, count: 32)
            rig.session.write(chunk)
            written += 32
            bytes += chunk.count
            try await Task.sleep(for: .milliseconds(10)) // test: the Mac's output rate
        }
        let counts = rig.screen.outputCounts
        let ticks = counts.frameTicks - before.frameTicks
        let pumps = counts.pumps - before.pumps
        let batches = counts.batches - before.batches
        let draws = rig.screen.surface.drawRequests - drawsBefore
        let line = "hidden-output: \(bytes / 1024) KB over \(duration) s hidden: display-link ticks \(ticks), pump calls \(pumps), batches \(batches), draw requests \(draws)"
        print(line)
        // The simulator step keeps attachments, not the console.
        Attachment.record(line, named: "hidden-output.txt")

        #expect(ticks == 0, "hidden: the output display link ran \(ticks) frames")
        // One coalesced batch per interval (and one more for a batch in flight at the end).
        let allowed = Int((duration / TerminalViewController.hiddenFeedInterval).rounded(.up)) + 1
        #expect(batches <= allowed, "hidden: \(batches) batches in \(duration) s, at most \(allowed)")
        #expect(draws == 0, "hidden: \(draws) frames asked of the renderer")

        // The last hidden batch lands; then one more write, and the page is shown.
        try await Task.sleep(for: .milliseconds(Int(TerminalViewController.hiddenFeedInterval * 1000) + 300)) // test: the hidden feed's next turn passes
        rig.session.write(Self.lines("last", from: 0, count: 1))
        #expect(rig.screen.outputPendingBytes > 0, "the write before the reveal waits while hidden")
        rig.show()
        // Shown: everything queued is with Ghostty in the same turn, before the first frame.
        #expect(rig.screen.outputPendingBytes == 0, "shown: \(rig.screen.outputPendingBytes) bytes still wait for a frame")
        try await Self.waitUntil(2) { rig.screen.surface.screenText()?.contains("last 0 ") == true }
        let text = rig.screen.surface.screenText() ?? ""
        #expect(text.contains("last 0 "), "shown: the last write is not on the page")
        #expect(text.contains("log \(written - 1) "), "shown: the last hidden line is not on the page")
    }

    /// A hidden page still pauses the Mac's output over the queue's high
    /// water and resumes it once the queue drains, and drops no byte.
    @Test func aHiddenPageKeepsBackpressureAndDropsNothing() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await Self.rig()
        defer { rig.window.isHidden = true }
        rig.hide()
        try await Task.sleep(for: .milliseconds(200)) // test: the reveal's own work settles

        // Over the high water in one go (a `cat` of a large file): written
        // until the screen pauses the Mac, with room for the batches it took
        // meanwhile, so the check does not depend on how many it took.
        var written = 0
        var bytes = 0
        while rig.session.pauses.isEmpty, bytes <= TerminalOutputQueue.highWater + (4 << 20) {
            let chunk = Self.lines("cat", from: written, count: 1024)
            rig.session.write(chunk)
            written += 1024
            bytes += chunk.count
        }
        #expect(rig.session.pauses.first == true, "over the high water: the Mac's output was not paused")
        try await Self.waitUntil(TerminalViewController.hiddenFeedInterval * 3 + 5) {
            rig.session.pauses.last == false && rig.screen.outputPendingBytes == 0
        }
        #expect(rig.session.pauses.last == false, "drained: the Mac's output never resumed (\(rig.session.pauses))")
        #expect(rig.screen.outputPendingBytes == 0, "hidden: \(rig.screen.outputPendingBytes) bytes never reached Ghostty")
        rig.show()
        try await Self.waitUntil(3) { rig.screen.surface.screenText()?.contains("cat \(written - 1) ") == true }
        #expect(rig.screen.surface.screenText()?.contains("cat \(written - 1) ") == true, "shown: the last line is not on the page")
    }
}
#endif
