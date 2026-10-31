import Foundation
import Testing
@testable import CmuxMobileAgentChat
#if os(iOS)
@testable import CmuxMobileDiff
#endif

/// Upstream changes made to the old SwiftUI transcript (`TurnView`, `AgentChatTurns`) and
/// diff screen, carried into the reused-row transcript (`ChatTranscriptBuilder`) and the
/// diff list (`DiffRenderModel`): the rows carry what those views read.
@MainActor
@Suite struct TranscriptRowPortTests {
    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(failed: Bool) -> AgentChatStore {
        let store = AgentChatStore(source: PromptResendTests.Recorder())
        store.apply(.userMessage(text: "Read this", promptId: "p", turnId: "t", attachments: [], at: Self.at))
        store.apply(.turnResult(turnId: "t", status: failed ? .failed : .completed, errorText: failed ? "unavailable" : nil, at: Self.at))
        return store
    }

    private func rows(_ store: AgentChatStore, builder: ChatTranscriptBuilder = ChatTranscriptBuilder(diffs: ChatDiffCache())) -> [ChatRow] {
        builder.build(turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false,
                      earlierHistory: store.hasEarlierHistory, retryPending: store.retryRequested).flatMap(\.rows)
    }

    /// #27374: a chat opened on capped history says "Showing messages since".
    @Test func theSessionLineSaysWhereCappedHistoryStarts() {
        let store = store(failed: false)
        guard case .sessionStart(_, let earlier)? = rows(store).first?.kind else {
            Issue.record("no session line")
            return
        }
        #expect(!earlier)
        store.apply(.earlierHistory(true))
        guard case .sessionStart(let date, let capped)? = rows(store).first?.kind else {
            Issue.record("no session line")
            return
        }
        #expect(capped)
        #expect(ChatRow.sessionLine(date, earlierHistory: true).hasPrefix("Showing messages since "))
        #expect(ChatRow.sessionLine(date, earlierHistory: false).hasPrefix("Session started "))
    }

    /// #27314: the failed turn's card retries through the store and turns its Retry off while
    /// the retry is in flight.
    @Test func aFailedTurnsRowRetriesOnce() throws {
        let store = store(failed: true)
        let builder = ChatTranscriptBuilder(diffs: ChatDiffCache())
        guard case .failed(let turn, let canRetry)? = rows(store, builder: builder).last?.kind else {
            Issue.record("no failure row")
            return
        }
        #expect(canRetry && turn.id == "t")
        store.retryFailedTurn(turn)
        guard case .failed(_, let after)? = rows(store, builder: builder).last?.kind else {
            Issue.record("no failure row")
            return
        }
        #expect(!after, "Retry is off while the retry is in flight")
    }

    /// #27318: Find in Chat's block keys map to the transcript rows that draw them.
    @Test func findKeysNameTheirRows() {
        let store = AgentChatStore(source: PromptResendTests.Recorder())
        store.apply(.userMessage(text: "Find me", promptId: "p", turnId: "t", attachments: [], at: Self.at))
        store.apply(.update(.agentMessageChunk(text: "First paragraph.\n\nSecond paragraph.", messageId: "m")))
        store.apply(.turnResult(turnId: "t", status: .completed, errorText: nil, at: Self.at))
        let rows = rows(store)
        let keyed = rows.compactMap { row in row.findKey.map { (row.id, $0) } }
        let blocks = AgentChatFind.blocks(of: store.turns).map(\.key)
        // Every searchable block has the row that draws it, and back.
        #expect(Set(keyed.map(\.1)) == Set(blocks))
        for (id, key) in keyed { #expect(ChatRow.rowID(forFindKey: key) == id) }
    }

    #if os(iOS)
    /// #27322: Search in File paints matches on the prepared text and finds each line's row.
    @Test func diffSearchPaintsMatchesAndFindsRows() throws {
        let file = DiffFile(path: "a.swift", edits: [(oldText: "let a = 1\nlet b = 2\n", newText: "let a = 1\nlet b = 3\nlet c = 4\n")])
        let key = DiffRenderKey(fileID: file.id, contentHash: file.contentHash, options: DiffRows.Options(),
                                style: DiffRenderStyle(codeSize: 13, wrap: false, split: false, width: 0))
        let model = DiffRenderModel(rows: DiffRows(file: file, options: key.options), key: key)
        for (line, _) in model.rows.lines.enumerated() {
            let row = try #require(model.rowByLine[line])
            guard case .line(let shown) = model.rows.rows[row] else {
            Issue.record("row \(row) is not a line")
            return
        }
            #expect(shown == line)
        }
        let line = try #require(DiffNavigation.matches("let c", in: model.rows.lines).first)
        let painted = model.text(line, search: "LET C")
        var found = false
        painted.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: painted.length)) { value, range, _ in
            if value != nil, (painted.string as NSString).substring(with: range).lowercased() == "let c" { found = true }
        }
        #expect(found, "the match is painted")
        #expect(model.text(line, search: "") === model.texts[line])
    }
    #endif
}
