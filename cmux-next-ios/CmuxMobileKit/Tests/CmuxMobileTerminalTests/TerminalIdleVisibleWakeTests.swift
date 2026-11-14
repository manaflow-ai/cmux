#if os(iOS)
import CmuxMobileArtifacts
import Foundation
import QuartzCore
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-14: "it's obvious just use less stuff to save battery? you
/// dont need a real battery". The simulator energy bench's `idle-terminal`
/// case (one terminal on screen at its prompt, no output arriving) cost
/// ~126 wakeups a second, against 0.13 for the idle home screen.
///
/// A terminal on screen with nothing arriving asks for no frames: no
/// display link of the page runs, nothing is asked of Ghostty's renderer,
/// and the renderer's own display link is stopped. Output still draws.
///
/// Through the real screen (`TerminalViewController`) and Ghostty surface;
/// the counters are `TerminalWakeCounts`. The line it prints is the
/// before/after harness of the change.
@MainActor
@Suite(.serialized) struct TerminalIdleVisibleWakeTests {
    /// A Mac terminal that writes what the test says, when it says.
    @MainActor
    final class ScriptedSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
        func setOutputPaused(_ paused: Bool) {}
        func write(_ data: Data) { handler?(.output(data)) }
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls the screen until a deadline
        }
    }

    /// The idle window's counters, by source.
    static func idleWindow(seconds: Double) async throws -> [String: UInt64] {
        let before = TerminalWakeCounts.snapshot()
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) // test: the idle window measured
        let after = TerminalWakeCounts.snapshot()
        return after.reduce(into: [:]) { out, entry in out[entry.key] = entry.value &- (before[entry.key] ?? 0) }
    }

    /// A screen at its prompt, on screen, with nothing arriving for 3 s.
    @Test func aVisibleIdleTerminalAsksForNoFrames() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let session = ScriptedSession()
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "idle")
        let screen = TerminalViewController(model: model, chrome: .embedded)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        root.addChild(screen)
        screen.view.frame = window.bounds
        root.view.addSubview(screen.view)
        screen.didMove(toParent: root)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Self.waitUntil(5) { session.handler != nil && screen.surface.surface != nil }
        try #require(session.handler != nil, "the screen never started its session")
        try #require(screen.surface.surface != nil, "libghostty created no surface")
        session.write(Data("Last login: Mon Oct 12 09:41:07 on ttys004\r\n~/Development/cmux $ ".utf8))
        try await Self.waitUntil(3) { screen.surface.screenText()?.contains("cmux $") == true }
        try #require(screen.surface.screenText()?.contains("cmux $") == true, "the prompt never reached the page")
        // The prompt's own frames and the page's settling pass.
        try await Task.sleep(for: .milliseconds(1500)) // test: the first output's frames land

        let seconds = 3.0
        let idle = try await Self.idleWindow(seconds: seconds)
        let line = "visible-idle: \(seconds) s, nothing arriving: "
            + idle.keys.sorted().map { "\($0)=\(idle[$0] ?? 0)" }.joined(separator: " ")
        print(line)
        // The simulator step keeps attachments, not the console.
        Attachment.record(line, named: "visible-idle.txt")

        for source in ["output-link", "follow-fallback", "glide", "fling", "autoscroll", "tui-momentum"] {
            #expect(idle[source] == 0, "idle: the page's \(source) display link ran \(idle[source] ?? 0) frames")
        }
        #expect(idle["draw-request"] == 0, "idle: \(idle["draw-request"] ?? 0) frames asked of Ghostty")
        #expect(idle["draw-now"] == 0, "idle: \(idle["draw-now"] ?? 0) frames drawn on main")
        #expect(idle["ghostty-frames"] == 0, "idle: Ghostty drew \(idle["ghostty-frames"] ?? 0) frames")
        // Ghostty's display link wakes its renderer once per refresh while it runs.
        #expect(idle["ghostty-draw-now"] == 0, "idle: Ghostty's display link ticked \(idle["ghostty-draw-now"] ?? 0) times")

        // Output still draws on a quiet page.
        let frames = screen.surface.renderedFrames
        session.write(Data("echo\r\nafter-idle\r\n".utf8))
        try await Self.waitUntil(3) { screen.surface.screenText()?.contains("after-idle") == true && screen.surface.renderedFrames > frames }
        #expect(screen.surface.renderedFrames > frames, "after idle, output drew no frame")
    }
}
#endif
