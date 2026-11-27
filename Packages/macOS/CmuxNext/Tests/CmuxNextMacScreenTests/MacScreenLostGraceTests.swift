import CmuxScreenKit
import Foundation
@testable import CmuxNextMacScreen
import Testing

/// The bridge socket closes a moment before `cmux rd connect` prints its `ended` line, so a lost
/// stream waits `lostGrace`: a cause arriving in that window reaches the card, else it says "lost".
@MainActor
@Suite struct MacScreenLostGraceTests {
    private func session() -> MacScreenSession {
        let session = MacScreenSession(title: "Box", preferences: ScreenPreferences(), signaling: { nil })
        session.lostGrace = .milliseconds(50)
        return session
    }

    @Test func aLinkCauseInsideTheGraceWins() async throws {
        let session = session()
        session.failLostUnlessLinkExplains(transport: nil)
        session.linkEnded("link failed: the secure handshake timed out")
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.failureCause == .link("the secure handshake timed out"))
        guard case let .failed(message, _) = session.phase else { Issue.record("not failed: \(session.phase)"); return }
        #expect(message != "The connection to the other Mac was lost.")
    }

    @Test func aHostCauseInsideTheGraceWins() async throws {
        let session = session()
        session.failLostUnlessLinkExplains(transport: nil)
        session.linkEnded("host: failed: capture stopped")
        try await Task.sleep(for: .milliseconds(300))
        guard case .host? = session.failureCause else { Issue.record("cause: \(String(describing: session.failureCause))"); return }
    }

    @Test func noLineMeansLost() async throws {
        let session = session()
        session.failLostUnlessLinkExplains(transport: nil)
        try await Task.sleep(for: .milliseconds(300))
        guard case let .failed(message, _) = session.phase else { Issue.record("not failed: \(session.phase)"); return }
        #expect(message == "The connection to the other Mac was lost.")
        #expect(session.failureCause == nil)
    }
}
