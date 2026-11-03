import CmuxMobileDiff
import CmuxMobileMarkdown
import Foundation
import Observation
import Testing
@testable import CmuxMobileAgentChat

/// The chat transcript's work per streamed token is O(changed rows): chunks coalesce to one
/// store change per frame, unchanged turns keep their rows, an answer re-parses its tail
/// only, and a diff is computed once per edit, off the main thread.
@MainActor
@Suite struct SmoothChatTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    static func turn(_ n: Int, edit: Bool = false, finished: Bool = true) -> [AgentSessionEvent] {
        var events: [AgentSessionEvent] = [
            .userMessage(text: "prompt \(n)", promptId: "p\(n)", turnId: "t\(n)", attachments: [], at: at),
            .turnStarted(turnId: "t\(n)", at: at),
            .update(.agentMessageChunk(text: "Answer **\(n)**\n\n- one\n- two\n\n```swift\nlet x = \(n)\n```\n", messageId: "m\(n)")),
        ]
        if edit {
            let old = (0..<400).map { "line \($0)" }.joined(separator: "\n")
            let new = (0..<400).map { $0 % 7 == 0 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n")
            events.append(.update(.toolCall(ACPToolCall(id: "c\(n)", title: "Edit a.swift", kind: .edit, status: .completed,
                                                        content: [.diff(path: "a.swift", oldText: old, newText: new)]))))
        }
        if finished { events.append(.turnResult(turnId: "t\(n)", status: .completed, errorText: nil, at: at)) }
        return events
    }

    // MARK: Coalescing

    /// Counts changes to what it watches (re-arming after each).
    @MainActor final class Changes {
        var count = 0

        func watch(_ read: @escaping @MainActor () -> Void) {
            withObservationTracking { read() } onChange: { [weak self] in
                Task { @MainActor in
                    self?.count += 1
                    self?.watch(read)
                }
            }
        }
    }

    /// Resumes waiting frames when the test says a frame went by.
    @MainActor final class Frames {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiting.count }

        func next() async { await withCheckedContinuation { waiting.append($0) } }

        func fire() {
            let resumed = waiting
            waiting = []
            for continuation in resumed { continuation.resume() }
        }
    }

    @Test func streamedChunksApplyOncePerFrame() async {
        let store = AgentChatStore(source: Silent())
        let frames = Frames()
        store.nextFrame = { await frames.next() }
        store.apply(.batch(Self.turn(0, finished: false)))
        let changes = Changes()
        changes.watch { _ = store.turns }
        for index in 0..<50 { store.receive(.update(.agentMessageChunk(text: "w\(index) ", messageId: "m0"))) }
        await Task.yield()
        #expect(store.turns[0].lastAnswerMarkdown?.hasSuffix("w49 ") == false, "chunks wait for the frame")
        while frames.count == 0 { await Task.yield() }
        frames.fire()
        for _ in 0..<5 { await Task.yield() }
        #expect(store.chunkFlushes == 1)
        #expect(store.turns[0].lastAnswerMarkdown?.hasSuffix("w48 w49 ") == true)
        #expect(changes.count == 1, "one store change for 50 chunks, got \(changes.count)")
    }

    @Test func otherEventsKeepTheirOrderAfterWaitingChunks() async {
        let store = AgentChatStore(source: Silent())
        let frames = Frames()
        store.nextFrame = { await frames.next() }
        store.apply(.batch(Self.turn(0, finished: false)))
        store.receive(.update(.agentMessageChunk(text: "tail", messageId: "m0")))
        store.receive(.turnResult(turnId: "t0", status: .completed, errorText: nil, at: Self.at))
        // The result applied the waiting chunk first.
        #expect(store.turns[0].lastAnswerMarkdown?.hasSuffix("tail") == true)
        #expect(store.turns[0].status == .completed)
        #expect(!store.isRunning)
    }

    @Test func mergedChunksKeepMessageBoundaries() {
        let merged = AgentChatStore.merged([
            .update(.agentMessageChunk(text: "a", messageId: "1")),
            .update(.agentMessageChunk(text: "b", messageId: "1")),
            .update(.agentMessageChunk(text: "c", messageId: "2")),
            .update(.agentThoughtChunk(text: "t")),
            .update(.agentThoughtChunk(text: "u")),
        ])
        #expect(merged.count == 3)
        if case .update(.agentMessageChunk(let text, let id)) = merged[0] { #expect(text == "ab" && id == "1") } else { Issue.record("not a chunk") }
    }

    /// The composer, the toolbar and the empty state read these; a token must not touch them.
    @Test func derivedStateDoesNotChangePerToken() async {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch(Self.turn(0, finished: false)))
        #expect(store.hasTurns && store.isRunning)
        let changes = Changes()
        changes.watch {
            _ = (store.hasTurns, store.isRunning, store.pendingPermission, store.pendingQuestion, store.firstPrompt,
                 store.hasAgentEdits, store.runningPlanEntries)
        }
        store.apply(.update(.agentMessageChunk(text: "more", messageId: "m0")))
        await Task.yield()
        #expect(changes.count == 0)
    }

    // MARK: Rows

    @Test func aTokenRebuildsOnlyTheStreamingTurn() {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch((0..<40).flatMap { Self.turn($0) } + Self.turn(40, finished: false)))
        let builder = ChatTranscriptBuilder(diffs: ChatDiffCache())
        let first = builder.build(turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false)
        #expect(builder.turnBuilds == 41)
        store.apply(.update(.agentMessageChunk(text: " more words", messageId: "m40")))
        let second = builder.build(turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false)
        #expect(builder.turnBuilds == 42, "only the streaming turn is built again")
        #expect(zip(first.dropLast(), second.dropLast()).allSatisfy { $0.generation == $1.generation })
        #expect(first.last?.generation != second.last?.generation)
        // Stable ids: the rows already shown keep theirs; the token added a block.
        let before = first.last?.rows.map(\.id) ?? []
        let after = second.last?.rows.map(\.id) ?? []
        #expect(after.starts(with: before.dropLast()) && after.count >= before.count)
    }

    @Test func rowIdsAreUniqueAndStable() {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch((0..<5).flatMap { Self.turn($0, edit: $0 == 4) }))
        let builder = ChatTranscriptBuilder(diffs: ChatDiffCache())
        let ids = builder.build(turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false).flatMap { $0.rows.map(\.id) }
        #expect(Set(ids).count == ids.count)
        #expect(ids.first == "session-start")
        #expect(ids.contains("u-t0") && ids.contains("a-t4") && ids.contains("e-c4"))
    }

    // MARK: Markdown

    @Test func incrementalParseMatchesAFullParse() {
        let answer = (0..<6).map { n in
            "## Part \(n)\n\nSome *text* with `code` and a [link](https://x.y).\n\n```swift\nfunc f\(n)() {\n    return\n}\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- a\n- b\n  continued\n\n> quote \(n)\n\n---"
        }.joined(separator: "\n\n")
        var parse = MarkdownStreamParse()
        var shown = ""
        var index = answer.startIndex
        var step = 1
        while index < answer.endIndex {
            let end = answer.index(index, offsetBy: step % 9 + 1, limitedBy: answer.endIndex) ?? answer.endIndex
            shown += answer[index..<end]
            index = end
            step += 1
            parse.update(shown, isStreaming: true)
            #expect(parse.blocks == MarkdownDocument(parsing: shown).blocks, "after \(shown.count) characters")
            #expect(parse.displayed == MarkdownDocument(parsing: MarkdownStreamTail(shown).displayed).blocks)
        }
        parse.update(answer, isStreaming: false)
        #expect(parse.displayed == MarkdownDocument(parsing: answer).blocks)
        // A token at the end of a long answer parses its last block, not the message.
        parse.update(answer + "\n\nTail words", isStreaming: true)
        parse.update(answer + "\n\nTail words and more", isStreaming: true)
        #expect(parse.lastParsedLines < 5, "parsed \(parse.lastParsedLines) lines")
    }

    @Test func aRewrittenMessageParsesFromTheStart() {
        var parse = MarkdownStreamParse("one\n\ntwo", isStreaming: true)
        parse.update("other text", isStreaming: false)
        #expect(parse.blocks == MarkdownDocument(parsing: "other text").blocks)
    }

    // MARK: Diffs

    @Test func eachEditIsDiffedOnceOffTheMainThread() async {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch((0..<3).flatMap { Self.turn($0, edit: $0 == 2) }))
        let cache = ChatDiffCache()
        let builder = ChatTranscriptBuilder(diffs: cache)
        _ = builder.build(turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false)
        // The snippet and the edited-files card: one diff each, still computing.
        #expect(cache.computations == 2)
        await cache.settle()
        for _ in 0..<20 {
            _ = builder.build(turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false)
        }
        #expect(cache.computations == 2)
        let rows = builder.build(turns: store.turns, pendingPermission: nil, askOpen: false, permissionBarHidden: false).last?.rows ?? []
        let card = rows.first { $0.id == "f-t2" }
        let snippet = rows.first { $0.id == "e-c2" }
        guard case .editedFiles(let changes)? = card?.kind, case .edit(_, let files)? = snippet?.kind else {
            Issue.record("rows: \(rows.map(\.id))")
            return
        }
        #expect(changes.files.count == 1 && changes.additions > 0)
        #expect(files?.count == 1)
        // Opening Changes reuses the computed diff.
        #expect(await cache.changeSetReady(for: store.turns[2]) == changes)
        #expect(cache.computations == 2)
    }

    /// A tap on a snippet before its turn's diff landed waits for the one computing, off the
    /// main thread, instead of running the diff on the main thread.
    @Test func openingChangesBeforeTheDiffLandsNeverDiffsOnTheMainThread() async {
        let store = AgentChatStore(source: Silent())
        store.apply(.batch((0..<3).flatMap { Self.turn($0, edit: $0 == 2) }))
        let cache = ChatDiffCache()
        let onMain = OnMainFlag()
        cache.compute = { inputs in
            if Thread.isMainThread { onMain.set() }
            return ChatDiffCache.diffFiles(inputs)
        }
        let changes = await cache.changeSetReady(for: store.turns[2])
        #expect(changes?.files.count == 1)
        #expect(cache.computations == 1)
        #expect(!onMain.value)
        // Ready now: the next open reuses it.
        #expect(await cache.changeSetReady(for: store.turns[2]) == changes)
        #expect(cache.computations == 1)
    }
}

/// The snippet's preview lines match `unifiedPreview` (the hunks with one line of context).
@Suite struct EditPreviewTests {
    @Test func previewLinesMatchUnifiedPreview() {
        let old = (0..<300).map { "line \($0)" }.joined(separator: "\n")
        let new = (0..<300).map { $0 % 7 == 0 || $0 % 11 == 0 ? "changed \($0)" : "line \($0)" }.joined(separator: "\n")
        let file = DiffFile(path: "a.swift", edits: [(oldText: old, newText: new)])
        let preview = ChatDiffCache.EditPreview(file)
        let short = file.unifiedPreview(maxLines: 12)
        let long = file.unifiedPreview(maxLines: 400)
        #expect(preview.short.lines == short.lines && preview.short.remaining == short.remaining)
        #expect(preview.long.lines == long.lines && preview.long.remaining == long.remaining)
    }
}

/// Review round 3: native rows at accessibility sizes, and revisions of rows that leave and return.
@Suite struct ChatNativeEligibilityTests {
    static func row(_ kind: ChatRow.Kind, id: String = "r") -> ChatRow { ChatRow(id: id, turnID: "t", kind: kind, gap: 0) }

    @Test func everyKindIsSwiftUIAtAccessibilitySizes() {
        let call = ACPToolCall(id: "c", title: "Read a.swift", kind: .read, status: .completed)
        let kinds: [ChatRow.Kind] = [
            .sessionStart(Date(), earlier: false), .prompt(text: "hi", attachments: [], at: Date(), isLast: true),
            .block(messageID: "m", block: MarkdownBlock(id: 0, kind: .paragraph("text"))),
            .block(messageID: "m", block: MarkdownBlock(id: 1, kind: .code(language: "swift", code: "let x = 1", isClosed: true))),
            .thought(text: "t", isLive: false), .tool(call), .toolGroup([call, call], turnRunning: false),
            .edit(call, files: []), .actions(AgentTurn(id: "t", prompt: "p", promptAt: Date()), isLast: true),
        ]
        for kind in kinds {
            #expect(ChatNativeEligibility.drawsNatively(Self.row(kind), accessibilitySize: false) { _ in nil }, "\(kind) is native at standard sizes")
            #expect(!ChatNativeEligibility.drawsNatively(Self.row(kind), accessibilitySize: true) { _ in nil }, "\(kind) is SwiftUI at AX sizes")
        }
    }

    @Test func openRowsAndMathStaySwiftUI() {
        let call = ACPToolCall(id: "c", title: "Read a.swift", kind: .read, status: .completed)
        #expect(!ChatNativeEligibility.drawsNatively(Self.row(.tool(call)), accessibilitySize: false) { $0 == "tool-c" ? true : nil })
        #expect(!ChatNativeEligibility.drawsNatively(Self.row(.thought(text: "t", isLive: false), id: "th"), accessibilitySize: false) { $0 == "thought-th" ? false : nil })
        let math = Self.row(.block(messageID: "m", block: MarkdownBlock(id: 0, kind: .math("x^2"))))
        #expect(!ChatNativeEligibility.drawsNatively(math, accessibilitySize: false) { _ in nil })
    }

    @Test func aRowThatReturnsGetsANewRevision() {
        var revisions = ChatRowRevisions()
        let first = revisions.bump("w-t1")
        revisions.bump("m-1#0")
        // The working label leaves (a tool row took its place) and comes back.
        revisions.retain(["m-1#0"])
        #expect(revisions["w-t1"] == nil)
        let again = revisions.bump("w-t1")
        #expect(again > first, "a returning row must not reuse revision \(first)")
        #expect(revisions.next == again + 1)
        revisions.removeAll()
        #expect(revisions.bump("w-t1") > again)
    }
}

/// Set from the diff's thread (tests).
final class OnMainFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

#if os(iOS)
import UIKit

/// A row queued for an off-main layout just before the environment changed (a rotation,
/// Dynamic Type, the code wrap setting) is queued again for the new one, not skipped until
/// the discarded batch lands (it would then be laid out on the main thread as it scrolls in).
@MainActor
@Suite struct NativeLayoutQueueTests {
    @MainActor final class Landed {
        var ids: [String] = []
    }

    @Test func aRowQueuedBeforeAnEnvironmentChangeIsLaidOutForTheNewOne() async throws {
        let layouts = ChatNativeLayouts()
        layouts.environment = ChatNativeEnvironment(width: 390, category: .large, wrapCode: false)
        let job = ChatNativeLayouts.Job(id: "r", revision: 1, kind: .stopped, expanded: false)
        let landed = Landed()
        layouts.prepare([job], urgent: true) { landed.ids += $0 }
        layouts.environment = ChatNativeEnvironment(width: 844, category: .large, wrapCode: false)
        layouts.prepare([job], urgent: true) { landed.ids += $0 }
        for _ in 0..<400 where landed.ids.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(landed.ids == ["r"])
        #expect(layouts.has("r", revision: 1, expanded: false))
        #expect(layouts.madeNow == 0)
    }

}

/// Find in Chat jumping to a block far up the transcript scrolls by the block's real height,
/// not its estimate: its off-main layout may not have landed yet, so the reveal lays it out first.
@MainActor
@Suite struct FindRevealLayoutTests {
    @Test func aRevealedRowIsLaidOutBeforeTheScroll() throws {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<20).flatMap { SmoothChatTests.turn($0) }))
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface())
        list.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        list.boundsMayHaveChanged()
        let items = list.layout.items
        try #require(!items.isEmpty, "no rows for \(store.turns.count) turns")
        // The oldest native rows wait for their off-main layout (only the newest are laid out at once).
        let id = try #require(items.first { !$0.exact && list.canLayOut($0.id) }?.id, "rows: \(items.prefix(16).map(\.id))")
        list.layOutNow(id)
        #expect(list.layout.items.first { $0.id == id }?.exact == true)
    }
}

/// A closed chat's transcript lets go of its store and surface: the list's pending
/// observation (registered with both) holds them only weakly.
@MainActor
@Suite struct TranscriptListReleaseTests {
    @Test func aClosedChatReleasesItsStoreAndSurface() {
        weak var weakStore: AgentChatStore?
        weak var weakSurface: AgentChatSurface?
        weak var weakList: ChatTranscriptList?
        autoreleasepool {
            let store = AgentChatStore(source: SmoothChatTests.Silent())
            store.nextFrame = nil
            store.apply(.batch((0..<3).flatMap { SmoothChatTests.turn($0) }))
            let surface = AgentChatSurface()
            let list = ChatTranscriptList(store: store, surface: surface)
            list.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
            list.boundsMayHaveChanged()
            weakStore = store
            weakSurface = surface
            weakList = list
        }
        #expect(weakList == nil)
        #expect(weakStore == nil)
        #expect(weakSurface == nil)
    }
}

/// Native answer rows keep what the SwiftUI blocks offered: a heading is a heading to
/// VoiceOver, and a block's long-press menu can select text, not only copy the whole message.
@MainActor
@Suite struct NativeBlockParityTests {
    static let environment = ChatNativeEnvironment(width: 350, category: .large, wrapCode: false)

    static func cell(_ kind: MarkdownBlock.Kind) throws -> ChatNativeRowCell {
        let layout = try #require(ChatNativeLayout.make(.block(messageID: "m", block: MarkdownBlock(id: 0, kind: kind)), id: "m#0",
                                                        expanded: false, environment: environment))
        let cell = ChatNativeRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: layout.height))
        var actions = ChatNativeActions()
        actions.message = { "## Plan\n\nShip it." }
        cell.apply(layout, actions: actions)
        return cell
    }

    static func traits(_ cell: ChatNativeRowCell) -> [UIAccessibilityTraits] {
        (cell.accessibilityElements ?? []).compactMap { ($0 as? NSObject)?.accessibilityTraits }
    }

    @Test func aHeadingReadsAsAHeading() throws {
        #expect(Self.traits(try Self.cell(.heading(level: 2, text: "Plan"))).contains { $0.contains(.header) })
        #expect(!Self.traits(try Self.cell(.paragraph("Ship it."))).contains { $0.contains(.header) })
    }

    @Test func aBlocksMenuOffersSelectText() throws {
        let titles = ChatNativeRowCell.messageMenu { "Ship it." }.compactMap { ($0 as? UIAction)?.title }
        #expect(titles.contains("Select Text"))
        #expect(titles.contains("Copy"))
    }
}
#endif
