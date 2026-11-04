#if os(iOS)
import CmuxConversationCore
import CmuxConversationUI
import Foundation
import Testing
import UIKit
@testable import CmuxMobileChief

/// The Chief conversation, open and resting at the bottom, keeps its loaded
/// window bounded while replies keep arriving: nobody scrolls a Chief chat
/// left open, so the bound must not wait for a scroll to end. The video proof
/// is the app's own: ChiefWindowBoundUITests (demo `chief-flood`).
@Suite(.serialized) @MainActor struct ChiefWindowBoundTests {
    @Test func liveRepliesWhileRestingAtTheBottomKeepTheWindowBounded() async throws {
        let backend = FloodBackend()
        let store = ConversationStore(backend: backend)
        let controller = ConversationViewController(store: store, options: .chief)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        window.layoutIfNeeded()
        try await until { store.hasLoadedNewest }
        try await settle(window)

        let batches = 32
        let perBatch = 50
        var seq = 0
        var maxLoaded = 0
        for batch in 1...batches {
            for _ in 0..<perBatch {
                seq += 1
                backend.push(seq: seq)
            }
            let expected = seq
            try await until { store.messages.last?.seq == expected }
            // The bound runs on the turn after the arrival lands.
            for _ in 0..<4 { await Task.yield() }
            try await settle(window)
            maxLoaded = max(maxLoaded, store.messages.count)
            print("CHIEF_WINDOW batch=\(batch) arrived=\(seq) loaded=\(store.messages.count) cells=\(Self.visibleCells(in: window))")
        }
        print("CHIEF_WINDOW final arrived=\(seq) loaded=\(store.messages.count) max=\(maxLoaded) threshold=\(ConversationStore.windowTrimThreshold)")
        #expect(store.messages.count <= ConversationStore.windowTrimThreshold)
        #expect(store.messages.last?.seq == seq)
        window.isHidden = true
        store.stop()
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("condition not met before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lets the view's own next-turn work (row landing, cell layout) run, then lays it out.
    private func settle(_ window: UIWindow) async throws {
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(16))
            window.layoutIfNeeded()
        }
    }

    private static func visibleCells(in view: UIView) -> Int {
        if let collection = view as? UICollectionView { return collection.visibleCells.count }
        return view.subviews.reduce(0) { $0 + visibleCells(in: $1) }
    }
}

/// A connected Chief conversation whose replies the test pushes live.
private final class FloodBackend: ConversationBackend, @unchecked Sendable {
    let info = ConversationInfo(id: "chief", title: "Chief", kind: .direct, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "chief", name: "Chief", initials: "C", colorHex: "#5E5CE6", isMe: false),
    ])
    private let lock = NSLock()
    private var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
    private let lines = [
        "a16 landed the iOS pagination on feat-cmux-next.",
        "The fleet build passed; the tag is published.",
        "Reviewing the Mac PR now, no blocking findings.",
        "iOS CI is green again after the lint fix.",
    ]

    func push(seq: Int) {
        let message = ConversationMessage(id: "m\(seq)", seq: seq, clientMessageID: nil, senderID: "chief",
                                          sentAt: Date(), text: "\(seq). \(lines[seq % lines.count])")
        _ = lock.withLock { continuation }?.yield(.message(message, eventSeq: seq))
    }

    func events() -> AsyncStream<ConversationBackendEvent> {
        let info = info
        return AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
            continuation.yield(.connected(info: info, meID: "me", lagged: false))
        }
    }

    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(messages: [], hasMore: false)
    }

    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func unsend(messageID: String) async throws -> ConversationMessage { throw ConversationBackendError(code: -1, message: "unsupported") }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { throw ConversationBackendError(code: -1, message: "unsupported") }
    func close() {}
}
#endif
