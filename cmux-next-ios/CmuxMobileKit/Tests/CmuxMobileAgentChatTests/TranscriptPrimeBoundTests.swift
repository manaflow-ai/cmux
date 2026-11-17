#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Review of #45287 (F1): priming the newest rows (`ChatTranscriptList.reload`) counted only native
/// rows, and stayed unprimed while it found none. A chat whose rows are all SwiftUI (every row at an
/// accessibility text size) walked every row of the chat on every reload, a streamed token's too.
/// Priming looks at a bounded number of rows once, then never again.
@MainActor
@Suite struct TranscriptPrimeBoundTests {
    @Test func aChatWithNoNativeRowIsPrimedOnceAndBounded() {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0 ..< 200).flatMap { SmoothChatTests.turn($0) } + SmoothChatTests.turn(200, finished: false)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface())
        host.view.addSubview(list.collectionView)
        list.collectionView.frame = host.view.bounds
        list.boundsMayHaveChanged()
        list.collectionView.layoutIfNeeded()
        let rows = list.layout.items.count
        #expect(rows > 2 * ChatTranscriptList.primeVisitLimit, "the chat has \(rows) rows")
        let afterOpen = list.primeVisits
        #expect(afterOpen <= ChatTranscriptList.primeVisitLimit, "rows looked at to prime on open: \(afterOpen)")
        for index in 0 ..< 50 {
            store.apply(.update(.agentMessageChunk(text: " word\(index)", messageId: "m200")))
            list.reload()
        }
        #expect(list.primeVisits == afterOpen, "50 tokens looked at \(list.primeVisits - afterOpen) more rows to prime")
    }
}
#endif
