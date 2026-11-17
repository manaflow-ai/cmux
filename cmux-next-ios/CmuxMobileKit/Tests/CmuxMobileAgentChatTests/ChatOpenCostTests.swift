#if os(iOS)
import Foundation
import QuartzCore
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-17: "the gui is fine on phone other than the jitter on load sometimes and layout
/// shift and the lack of themeing/background inheriting (these need to be improved)".
///
/// The main thread's work while a long chat opens, from the transcript's first reload until every
/// off-main row layout has landed: the list rig's 200-turn fixture (prompt, thought, read, edit with
/// a diff, test run, markdown answer with code and a table).
@MainActor
@Suite struct ChatOpenCostTests {
    static func stressTurns(_ count: Int) -> [AgentSessionEvent] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var events: [AgentSessionEvent] = []
        for index in 0..<count {
            let turnID = "stress-\(index)"
            let at = base.addingTimeInterval(Double(index) * 2)
            events.append(.userMessage(text: MockStressContent.prompt(index), promptId: "p-\(turnID)", turnId: turnID, attachments: [], at: at))
            events.append(.turnStarted(turnId: turnID, at: at))
            events.append(.update(.agentThoughtChunk(text: MockStressContent.thought(index))))
            events.append(.update(.toolCall(ACPToolCall(
                id: "\(turnID)-read", title: "Read LinkDialer.swift", kind: .read, status: .completed,
                content: [.content(.text(MockStressContent.code(lines: 12, seed: index)))],
                locations: [.init(path: "CmuxMobileTransport/LinkDialer.swift")]
            ))))
            events.append(.update(.toolCall(ACPToolCall(
                id: "\(turnID)-edit", title: "Edit Stress\(index).swift", kind: .edit, status: .completed,
                content: [.diff(path: "Sources/Stress\(index).swift", oldText: MockStressContent.code(lines: 30, seed: index),
                                newText: MockStressContent.code(lines: 30, seed: index, edited: true))]
            ))))
            events.append(.update(.toolCall(ACPToolCall(
                id: "\(turnID)-run", title: "swift test --filter Link", kind: .execute, status: .completed,
                content: [.content(.text(MockStressContent.testOutput(index)))],
                rawInput: .object(["command": .string("swift test --filter Link")])
            ))))
            events.append(.update(.agentMessageChunk(text: MockStressContent.answer(index), messageId: "\(turnID)-m")))
            events.append(.turnResult(turnId: turnID, status: .completed, errorText: nil, at: at.addingTimeInterval(1)))
        }
        return events
    }

    /// Opens the fixture as the transcript controller does (the list, then its first width, then a
    /// layout pass), and waits for the off-main layouts to land. Returns the list.
    static func open(turns: Int) async -> (list: ChatTranscriptList, window: UIWindow) {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch(stressTurns(turns)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        var t = CACurrentMediaTime()
        func lap() -> String { let now = CACurrentMediaTime(); defer { t = now }; return String(format: "%.1f", (now - t) * 1000) }
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface())
        let initMs = lap()
        list.collectionView.frame = window.bounds
        window.addSubview(list.collectionView)
        window.isHidden = false
        list.boundsMayHaveChanged()
        let widthMs = lap()
        list.collectionView.contentOffset.y = max(0, list.layout.collectionViewContentSize.height - 874)
        list.collectionView.layoutIfNeeded()
        let layoutMs = lap()
        print("CHATOPENCOST first-frame init=\(initMs) width=\(widthMs) layout=\(layoutMs)")
        // Every native row's layout lands (off the main thread), with the reloads it causes.
        for _ in 0..<1000 {
            try? await Task.sleep(for: .milliseconds(10))
            if list.layout.items.allSatisfy({ $0.exact || !list.canLayOut($0.id) }) { break }
        }
        try? await Task.sleep(for: .milliseconds(100))
        _ = lap()
        list.collectionView.layoutIfNeeded()
        print("CHATOPENCOST landed-layout=\(lap())")
        return (list, window)
    }

    @Test func reportsTheOpensMainThreadWork() async {
        let (list, window) = await Self.open(turns: 200)
        defer { window.isHidden = true }
        let ms = Double(list.reloadTime.components.attoseconds) / 1e15 + Double(list.reloadTime.components.seconds) * 1000
        print("CHATOPENCOST rows=\(list.layout.items.count) applies=\(list.applies) snapshotApplies=\(list.snapshotApplies) "
              + "rowsWeighed=\(list.rowsWeighed) madeNow=\(list.layoutsMadeNow) reloadMs=\(String(format: "%.1f", ms)) "
              + "reloads=\(list.reloadLog.map { String(format: "%.1f", $0) }.joined(separator: ","))")
        #expect(list.layout.items.count > 1000)
    }
}
#endif
