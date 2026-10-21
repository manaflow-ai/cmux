import Foundation
import Testing
@testable import CmuxMobileTerminal

/// A stand-in for the Mac's terminal session (`DaemonTerminalSession`).
@MainActor
private final class LiveStub: TerminalSession {
    let programName = "zsh"
    let isAlternateScreen = false
    func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
    func send(_ bytes: Data) {}
    func resize(columns: Int, rows: Int) {}
    func stop() {}
}

/// A live signed-in session never shows the scripted mock terminal: the mock
/// is DEBUG-only and needs the explicit mock data setting.
@MainActor
@Suite struct TerminalSessionChoiceTests {
    @Test func liveSessionAlwaysWins() {
        let live = LiveStub()
        for mock in [false, true] {
            let chosen = TerminalSessionChoice.session(live: live, mockDataEnabled: mock, macName: "Studio", programName: "zsh")
            #expect(chosen === live)
        }
    }

    @Test func liveTabWithoutSessionIsConnectingNotMock() {
        let chosen = TerminalSessionChoice.session(live: nil, mockDataEnabled: false, macName: "Aziz's Mac Studio", programName: "zsh")
        #expect(chosen is PendingTerminalSession)
        #if DEBUG
        #expect(!(chosen is MockTerminalSession))
        #endif
        #expect(chosen.connectionState == .connecting(mac: "Aziz's Mac Studio"))
        #expect(chosen.connectionState.label == "Connecting to Aziz's Mac Studio…")
        #expect(chosen.programName == "zsh")
    }

    #if DEBUG
    @Test func mockOnlyWithTheExplicitSetting() {
        #expect(TerminalSessionChoice.mockCompiledIn)
        let chosen = TerminalSessionChoice.session(live: nil, mockDataEnabled: true, macName: nil, programName: "zsh")
        #expect(chosen is MockTerminalSession)
        #expect(TerminalSessionChoice.fallbackArtifactSource(mockDataEnabled: true) is MockArtifactSource)
    }
    #endif

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
        #expect(session.connectionState.label == "Connecting…")
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
        #expect(TerminalConnectionState.reattaching(mac: "mini").label == "Reattaching…")
        #expect(TerminalConnectionState.attached.label == nil)
    }
}
