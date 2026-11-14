#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-14 (ask-9ccd5a07ab): "Keys typed while your Mac was
/// unreachable were not sent." showed when "all I did was navigate away ...
/// I didn't type anything". A scroll or a tap over a TUI writes mouse
/// reports, and the screen handed them to the session as typed keys: held
/// through a link change and dropped, they made the notice.
///
/// Through the real screen (`TerminalViewController`) and Ghostty surface:
/// only a key press, typed text or a paste reaches `send` (keys that may be
/// reported as not sent); the reports of a scroll or tap reach `sendReply`.
@MainActor
@Suite(.serialized) struct TerminalUntypedInputNoticeTests {
    @MainActor
    final class RecordingSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        let connectionState: TerminalConnectionState = .attached
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        private(set) var typed: [Data] = []
        private(set) var replies: [Data] = []
        private(set) var interactions = 0

        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }
        func send(_ bytes: Data) { typed.append(bytes) }
        func sendReply(_ bytes: Data) { replies.append(bytes) }
        func noteInteraction() { interactions += 1 }
        func resize(columns: Int, rows: Int) {}
        func stop() {}
        func write(_ bytes: Data) { handler?(.output(bytes)) }
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls the screen until a deadline
        }
    }

    @Test func aScrollOrTapOverATUIIsNoTypedKey() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let session = RecordingSession()
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "untyped")
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Self.waitUntil(5) { session.handler != nil && screen.surface.prediction != nil }
        try #require(session.handler != nil, "the screen never started its session")
        // A full-screen app that asked for mouse reports (as Claude Code does).
        session.write(Data("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h$ ".utf8))
        try await Task.sleep(for: .milliseconds(300)) // test: the setup's frames land

        let cell = try #require(screen.surface.visibleCursorCell, "the cursor is not on screen")
        let point = CGPoint(x: cell.midX, y: cell.midY)
        try #require(screen.surface.click(at: point), "the mouse is not captured")
        screen.surface.scrollWheel(at: point, deltaY: cell.height * 3, momentum: .none)
        try await Self.waitUntil(1) { session.replies.count >= 2 }

        #expect(session.typed.isEmpty, "a tap or scroll went out as typed keys: \(session.typed.map { Array($0) })")
        #expect(session.replies.count >= 2, "the tap and scroll reports never went out")
        #expect(session.interactions > 0, "a tap or scroll is still the person's interaction")

        // A typed key is still a typed key.
        screen.surface.perform([.text("z")])
        try await Self.waitUntil(1) { !session.typed.isEmpty }
        #expect(session.typed == [Data("z".utf8)])
        #expect(model.composerNotice == nil)
    }
}
#endif
