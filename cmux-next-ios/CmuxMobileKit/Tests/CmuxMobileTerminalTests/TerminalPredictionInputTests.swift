#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Review of #38475 (predictive local echo on the phone): prediction takes
/// only what the person typed, pressed or pasted, and only once the session
/// took it to go out.
///
/// - Ghostty writes its own bytes too (terminal replies, mouse and focus
///   reports). Fed to the engine as input, each one withdrew or fenced off
///   what was drawn, and the keys typed after it showed a round trip late.
/// - A key the session refused or held through an outage never echoes, so a
///   glyph predicted for it stood on screen until it timed out.
///
/// Through the real screen (`TerminalViewController`) and Ghostty surface,
/// over a session that echoes typed text a round trip later.
@MainActor
@Suite(.serialized) struct TerminalPredictionInputTests {
    /// A shell on a Mac 120 ms away, as the screen sees it.
    @MainActor
    final class EchoSession: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        var connectionState: TerminalConnectionState = .attached
        private(set) var handler: (@MainActor (TerminalSessionEvent) -> Void)?
        /// Echoes printable input after `roundTrip`.
        var echoes = true
        /// Refuses input as `DaemonTerminalSession` does once keys were dropped.
        var refuses = false
        private(set) var received: [Data] = []
        let roundTrip = Duration.milliseconds(120)

        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) { self.handler = handler }

        func send(_ bytes: Data) {
            if refuses {
                handler?(.inputNotSent(bytes: bytes.count))
                return
            }
            received.append(bytes)
            guard echoes, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return }
            let wait = roundTrip
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait) // test: the link's round trip
                // Not once the test stopped echoes: nothing reaches a
                // screen after its test (`TerminalScreenTestLock`).
                guard let self, echoes else { return }
                write(bytes)
            }
        }

        func resize(columns: Int, rows: Int) {}
        func stop() {}

        func write(_ bytes: Data) { handler?(.output(bytes)) }

        func connection(_ state: TerminalConnectionState) {
            connectionState = state
            handler?(.connection(state))
        }
    }

    @MainActor
    struct Screen {
        let screen: TerminalViewController
        let session: EchoSession
        let window: UIWindow
        let prediction: TerminalSurfacePrediction

        func close() {
            session.echoes = false
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls the screen until a deadline
        }
    }

    /// A prompt on screen. `setup` is output the remote sends before it.
    static func makeScreen(setup: String = "") async throws -> Screen {
        let session = EchoSession()
        let model = TerminalModel(session: session, artifactSource: MockArtifactSource(), title: "prediction")
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        try await waitUntil(5) { session.handler != nil && screen.surface.prediction != nil }
        try #require(session.handler != nil, "the screen never started its session")
        let prediction = try #require(screen.surface.prediction, "the surface has no prediction")
        session.write(Data((setup + "$ ").utf8))
        try await Task.sleep(for: .milliseconds(300)) // test: the prompt's frames land
        return Screen(screen: screen, session: session, window: window, prediction: prediction)
    }

    /// Whether `key` is drawn as a speculative glyph.
    static func predicts(_ key: Character, _ prediction: TerminalSurfacePrediction) -> Bool {
        prediction.drawnLayout?.glyphs.contains { $0.character == key.asciiValue && $0.standing == 0 } == true
    }

    /// Types at the prompt until a key shows before its echo (two echoed
    /// keys measure the link, then the engine predicts).
    static func engage(_ screen: Screen) async throws {
        for key in "lsabcdefgh" {
            screen.screen.surface.perform([.text(String(key))])
            if predicts(key, screen.prediction) { return }
            try await Task.sleep(for: .milliseconds(400)) // test: the echo and its frame land
        }
        Issue.record("prediction never engaged (status \(screen.prediction.engine.status(nowUs: TerminalSurfacePrediction.now())))")
    }

    @Test func ghosttysOwnWritesLeavePredictionAlone() async throws {
        // A program that asked for mouse reports: a tap is a click it reads.
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let screen = try await Self.makeScreen(setup: "\u{1B}[?1000h")
        defer { screen.close() }
        try await Self.engage(screen)
        try #require(screen.prediction.drawnLayout != nil, "nothing drawn to keep")
        screen.session.echoes = false

        let cell = try #require(screen.screen.surface.visibleCursorCell, "the cursor is not on screen")
        let reports = screen.session.received.count
        try #require(screen.screen.surface.click(at: CGPoint(x: cell.midX, y: cell.midY)), "the mouse is not captured")
        try await Self.waitUntil(1) { screen.session.received.count > reports }
        let report = try #require(screen.session.received.last, "Ghostty wrote no mouse report")
        #expect(report.starts(with: [0x1B, 0x5B, 0x4D]), "not a mouse report: \(Array(report))")

        // The click was Ghostty's report, not a keystroke: the next key
        // still shows at once.
        screen.screen.surface.perform([.text("z")])
        #expect(Self.predicts("z", screen.prediction), "a mouse report stopped prediction")
    }

    @Test func aMouseReportTheSessionRefusesDoesNotFreezeTheScreen() async throws {
        // Ghostty writes a mouse report while it holds its renderer lock, and
        // the session's refusal comes back inside that write: withdrawing
        // the glyphs must not ask Ghostty for the cursor (it would wait on
        // the lock forever).
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let screen = try await Self.makeScreen(setup: "\u{1B}[?1000h")
        defer { screen.close() }
        try await Self.engage(screen)
        try #require(screen.prediction.drawnLayout != nil, "nothing drawn before the refusal")
        screen.session.echoes = false
        screen.session.refuses = true

        let cell = try #require(screen.screen.surface.visibleCursorCell, "the cursor is not on screen")
        try #require(screen.screen.surface.click(at: CGPoint(x: cell.midX, y: cell.midY)), "the mouse is not captured")
        try await Self.waitUntil(1) { screen.prediction.drawnLayout == nil }
        #expect(screen.prediction.drawnLayout == nil, "glyphs stayed for a link that refuses input")
        screen.screen.surface.perform([.text("z")])
        #expect(!Self.predicts("z", screen.prediction), "a refused key was predicted")
    }

    @Test func aKeyTypedWhileTheLinkIsDownIsNotPredicted() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let screen = try await Self.makeScreen()
        defer { screen.close() }
        try await Self.engage(screen)
        try #require(screen.prediction.drawnLayout != nil, "nothing drawn before the drop")
        screen.session.echoes = false

        // The link drops: what was in flight may never echo, and a key
        // typed now is held for the reattach, not sent.
        screen.session.connection(.reattaching(mac: nil))
        #expect(screen.prediction.drawnLayout == nil, "glyphs in flight stayed after the link dropped")
        screen.screen.surface.perform([.text("z")])
        #expect(!Self.predicts("z", screen.prediction), "a key held for the reattach was predicted")
        #expect(screen.prediction.drawnLayout == nil)
    }

    @Test func aKeyTheSessionRefusesIsNotPredicted() async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let screen = try await Self.makeScreen()
        defer { screen.close() }
        try await Self.engage(screen)
        try #require(screen.prediction.drawnLayout != nil, "nothing drawn before the refusal")
        screen.session.echoes = false

        // The session says at once that the key did not go (keys were
        // already dropped in an outage).
        screen.session.refuses = true
        screen.screen.surface.perform([.text("z")])
        #expect(!Self.predicts("z", screen.prediction), "a refused key was predicted")
        #expect(screen.prediction.drawnLayout == nil, "glyphs stayed for keys that will never echo")
    }
}
#endif
