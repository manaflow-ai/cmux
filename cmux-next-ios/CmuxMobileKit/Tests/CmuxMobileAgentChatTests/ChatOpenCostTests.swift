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

    /// The history's off-main layouts landing give the landed rows their real heights and weigh no
    /// other row again: before, each landed batch dropped its turns' kept rows (and a batch laid out
    /// for a row's older revision dropped its turn too), so the open weighed the whole history again
    /// on the main thread.
    @Test func landedLayoutsWeighNoRowAgain() async {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch(Self.stressTurns(60)))
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface())
        list.collectionView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        list.boundsMayHaveChanged()
        let weighedAtOpen = list.rowsWeighed
        list.weighReasons = []
        let waiting = list.layout.items.filter { !$0.exact && list.canLayOut($0.id) }.count
        #expect(waiting > 100, "the oldest rows wait for their off-main layout")
        for _ in 0..<1000 {
            try? await Task.sleep(for: .milliseconds(10))
            if list.layout.items.allSatisfy({ $0.exact || !list.canLayOut($0.id) }) { break }
        }
        #expect(list.layout.items.allSatisfy { $0.exact || !list.canLayOut($0.id) }, "every native row has its real height")
        let reasons = Dictionary(list.weighReasons.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("CHATOPENCOST weighed-again \(reasons) applies=\(list.applies)")
        // A turn whose rows changed meanwhile (its diff landed, off the main thread: an edited-files
        // row and an actions row come in) weighs the rows it added or moved. No turn is weighed whole
        // again because a layout landed (`noPrevious`), and nothing near the whole history is.
        let whole = list.weighReasons.filter { $0.hasPrefix("noPrevious:") }
        #expect(whole.isEmpty, "rows of dropped turns weighed again: \(whole.count) of \(list.layout.items.count): \(reasons)")
        #expect(list.weighReasons.count * 4 < list.layout.items.count, "rows weighed again: \(list.weighReasons.count) of \(list.layout.items.count): \(reasons)")
    }

    /// The open's weighing grows with the history, not with its square: 4x the turns costs well under
    /// 16x the time. Each row written through the list's row table copied the whole table (a get/set
    /// computed property), so an open of N rows copied N tables of N rows.
    @Test func openWeighingGrowsLinearly() {
        func firstReload(_ turns: Int) -> Double {
            let store = AgentChatStore(source: SmoothChatTests.Silent())
            store.nextFrame = nil
            store.apply(.batch(Self.stressTurns(turns)))
            let list = ChatTranscriptList(store: store, surface: AgentChatSurface())
            list.collectionView.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            let before = list.reloadTime
            list.boundsMayHaveChanged()
            let took = list.reloadTime - before
            return Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15
        }
        _ = firstReload(20)
        let small = min(firstReload(100), firstReload(100))
        let large = min(firstReload(400), firstReload(400))
        print("CHATOPENCOST weigh 100 turns \(String(format: "%.1f", small)) ms, 400 turns \(String(format: "%.1f", large)) ms")
        #expect(large < small * 8, "400 turns took \(large) ms against \(small) ms for 100")
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
