import CmuxMobileDesign
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// A stand-in for the Mac's terminal session (`DaemonTerminalSession`).
@MainActor
private final class LiveStub: TerminalSession {
    let programName = "zsh"
    let isAlternateScreen = false
    var preservesHostGrid = false
    func setPreservesHostGrid(_ preserves: Bool) { preservesHostGrid = preserves }
    func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
    func send(_ bytes: Data) {}
    func resize(columns: Int, rows: Int) {}
    func stop() {}
}

/// A live signed-in session never shows the scripted terminal: it needs demo
/// content (DEBUG mock mode, or the server-flagged App Review demo account).
@MainActor
@Suite struct TerminalSessionChoiceTests {
    #if os(iOS)
    @Test func macGridIsDefaultAndProjectionAndFitRemainExplicitChoices() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let live = LiveStub()
        func choose() -> any TerminalSession {
            TerminalSessionChoice.session(live: live, mockDataEnabled: false, macName: "Mac", programName: "zsh", defaults: defaults)
        }
        #expect(choose() === live)
        #expect(live.preservesHostGrid)
        defaults.set(true, forKey: CmuxMobilePreferences.Key.terminalPhoneProjection)
        #expect(choose() is TerminalProjectingSession)
        #expect(!live.preservesHostGrid)
        defaults.set(true, forKey: CmuxMobilePreferences.Key.terminalFitToPhone)
        #expect(choose() === live)
        #expect(!live.preservesHostGrid, "Fit to Phone still explicitly resizes the Mac")
        TerminalFitToPhoneMemory(defaults: defaults).set(false, for: "zsh")
        #expect(choose() is TerminalProjectingSession, "the per-program choice wins over global Fit to Phone")
        defaults.set(false, forKey: CmuxMobilePreferences.Key.terminalPhoneProjection)
        #expect(choose() === live)
        #expect(live.preservesHostGrid)
    }
    #endif

    @Test func liveSessionAlwaysWins() {
        let live = LiveStub()
        for mock in [false, true] {
            let chosen = TerminalSessionChoice.session(live: live, mockDataEnabled: mock, macName: "Studio", programName: "zsh")
            // The live session itself, or opt-in projection on iOS
            // the phone's projection of it: never the mock.
            #expect(chosen.underlyingSession === live)
            #if os(iOS)
            if TerminalProjectingSession.isEnabled(for: live.programName) {
                #expect(chosen is TerminalProjectingSession)
            } else {
                #expect(chosen === live)
            }
            #else
            #expect(chosen === live)
            #endif
        }
    }

    @Test func liveTabWithoutSessionIsConnectingNotMock() {
        let chosen = TerminalSessionChoice.session(live: nil, mockDataEnabled: false, macName: "Aziz's Mac Studio", programName: "zsh")
        #expect(chosen is PendingTerminalSession)
        #expect(!(chosen is MockTerminalSession))
        #expect(chosen.connectionState == .connecting(mac: "Aziz's Mac Studio"))
        #expect(chosen.connectionState.quietLine == "Connecting to Aziz's Mac Studio…")
        #expect(chosen.programName == "zsh")
    }

    /// Demo content (DEBUG mock mode, or the App Review demo account in any build)
    /// gets the scripted shell and its sample files; nothing else does.
    @Test func demoShellOnlyWithDemoContent() {
        let chosen = TerminalSessionChoice.session(live: nil, mockDataEnabled: true, macName: nil, programName: "zsh")
        #expect(chosen is MockTerminalSession)
        #expect(TerminalSessionChoice.fallbackArtifactSource(mockDataEnabled: true) is MockArtifactSource)
    }

    /// The review demo's shell answers typed commands like a Mac's: no mock
    /// labels, a prompt, and output for a command it knows.
    @Test func demoShellAnswersACommand() async throws {
        let session = MockTerminalSession(playsIntro: false)
        var output = ""
        session.start { event in
            if case .output(let data) = event { output += String(decoding: data, as: UTF8.self) }
        }
        defer { session.stop() }
        try await Self.waitUntil(5) { output.contains("❯") }
        try #require(output.contains("❯"), "the demo shell never showed its prompt")
        session.send(Data("echo hello from the demo\r".utf8))
        // Twice: the typed line the shell echoes, then echo's own output.
        try await Self.waitUntil(5) { output.components(separatedBy: "hello from the demo").count > 2 }
        #expect(output.components(separatedBy: "hello from the demo").count > 2)
        session.send(Data([0x04]))
        try await Self.waitUntil(5) { output.contains("exit is disabled") }
        #expect(output.contains("exit is disabled in this session"))
        #expect(!output.contains("(mock)"))
    }

    /// The review demo's terminal opens on its last commands at once and takes the
    /// reviewer's typing right away (a typed-out intro dropped keys for seconds).
    @Test func reviewDemoShellIsReadyAtOnce() async throws {
        let chosen = TerminalSessionChoice.session(live: nil, mockDataEnabled: true, reviewDemo: true, macName: nil, programName: "zsh")
        let session = try #require(chosen as? MockTerminalSession)
        var output = ""
        session.start { event in
            if case .output(let data) = event { output += String(decoding: data, as: UTF8.self) }
        }
        defer { session.stop() }
        try await Self.waitUntil(1) { output.contains("Finished") }
        #expect(output.contains("Finished"), "the intro's build finished within a second")
        session.send(Data("echo ready\r".utf8))
        try await Self.waitUntil(2) { output.components(separatedBy: "ready").count > 2 }
        #expect(output.components(separatedBy: "ready").count > 2, "the first typed command ran")
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test: polls the demo shell's output until a deadline
        }
    }

    @Test func filesAndLinksWithoutAMacSayNotConnected() async {
        let source = TerminalSessionChoice.fallbackArtifactSource(mockDataEnabled: false)
        #expect(source is UnavailableArtifactSource)
        let artifact = TerminalArtifact(reference: "README.md", kind: .markdown, order: 0)
        await #expect(throws: ArtifactUnavailable.self) { try await source.load(artifact) }
    }

    @Test func pendingSessionReportsConnectingAndDropsInput() {
        let session = PendingTerminalSession(macName: nil)
        var events: [TerminalSessionEvent] = []
        session.start { events.append($0) }
        session.send(Data("ls\r".utf8))
        session.resize(columns: 80, rows: 24)
        #expect(events == [.connection(.connecting(mac: nil))])
        #expect(session.connectionState.quietLine == "Connecting to your Mac…")
    }
}

@Suite struct TerminalConnectionStateTests {
    @Test func eventsDriveTheState() {
        let connecting = TerminalConnectionState.connecting(mac: "mini")
        #expect(!connecting.isAttached)
        #expect(connecting.applying(.title("zsh")) == connecting)
        #expect(connecting.applying(.connection(.attached)) == .attached)
        // Bytes from the Mac mean attached, even without a `.connection` event.
        #expect(connecting.applying(.output(Data("$ ".utf8))) == .attached)
        #expect(TerminalConnectionState.attached.applying(.connection(.reattaching(mac: "mini"))) == .reattaching(mac: "mini"))
        #expect(TerminalConnectionState.reattaching(mac: "mini").quietLine == "Reconnecting to mini…")
        #expect(TerminalConnectionState.attached.quietLine == nil)
    }
}
