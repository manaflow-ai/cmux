#if os(iOS)
import CmuxMobileTransport
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// The `markdown-web` piece decides which transcript rows go to the web renderer (math), and
/// the transcript keeps native row layouts made under one answer. A changed answer
/// (`MobilePieces.didChangeNotification`) lays the rows out again; the same environment
/// without one lays nothing out again.
@MainActor
@Suite struct PiecesChangeLayoutTests {
    private func made(_ list: ChatTranscriptList) -> Int { list.layoutsMadeNow + list.layoutsMadeOffMain }

    /// Waits until no layout has landed for 100 ms (at most 4 s).
    private func settle(_ list: ChatTranscriptList) async throws {
        var last = made(list)
        var quiet = 0
        for _ in 0..<400 where quiet < 10 {
            try await Task.sleep(for: .milliseconds(10))
            let now = made(list)
            quiet = now == last ? quiet + 1 : 0
            last = now
        }
    }

    @Test func aChangedKillSwitchAnswerLaysTheRowsOutAgain() async throws {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<6).flatMap { SmoothChatTests.turn($0) }))
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface())
        list.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        list.boundsMayHaveChanged()
        try await settle(list)
        let before = made(list)
        try #require(before > 0, "no native rows laid out")

        // The same environment: nothing is laid out again.
        list.boundsMayHaveChanged()
        try await settle(list)
        #expect(made(list) == before)

        NotificationCenter.default.post(name: MobilePieces.didChangeNotification, object: MobilePieces.shared)
        for _ in 0..<400 where made(list) == before { try await Task.sleep(for: .milliseconds(10)) }
        #expect(made(list) > before)
    }
}
#endif
