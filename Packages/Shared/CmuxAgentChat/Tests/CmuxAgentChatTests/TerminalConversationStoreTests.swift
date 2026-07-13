import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("Terminal ChatConversationStore")
struct TerminalConversationStoreTests {
    private static let baseTime = Date(timeIntervalSinceReferenceDate: 0)

    private static func terminalDescriptor() -> ChatSessionDescriptor {
        ChatSessionDescriptor(id: "term-1", agentKind: .other("shell"), kind: .terminal)
    }

    @MainActor
    private static func makeStore(_ source: any ChatEventSource) -> ChatConversationStore {
        ChatConversationStore(descriptor: terminalDescriptor(), source: source, now: { baseTime })
    }

    private static func blocks(_ rows: [ChatTranscriptRow]) -> [TerminalCommandBlock] {
        rows.compactMap { if case .terminalCommand(let b) = $0 { return b }; return nil }
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await MainActor.run(body: condition) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await MainActor.run(body: condition)
    }

    private static func pendings(_ rows: [ChatTranscriptRow]) -> [ChatPendingOutbound] {
        rows.compactMap { if case .pendingOutbound(let p) = $0 { return p }; return nil }
    }

    @Test("reset clears terminal blocks (no stale render after a transcript reset)")
    @MainActor func resetClearsBlocks() async {
        let source = FixtureChatEventSource(terminalBacklog: [
            TerminalCommandBlock(id: 0, command: "ls", output: "a\n", exitCode: 0, isRunning: false),
            TerminalCommandBlock(id: 1, command: "pwd", output: "/tmp\n", exitCode: 0, isRunning: false),
        ])
        let store = Self.makeStore(source)
        let run = Task { await store.run() }
        defer { run.cancel() }
        #expect(await Self.waitUntil { store.isConnected && Self.blocks(store.rows).count == 2 })
        await source.emit(.reset)
        #expect(await Self.waitUntil { Self.blocks(store.rows).isEmpty })
    }

    @Test("a terminal send shows a pending row, then reconciles when its command echoes as a block")
    @MainActor func sendPendingReconciles() async {
        let source = FixtureChatEventSource(terminalBacklog: [])
        let store = Self.makeStore(source)
        let run = Task { await store.run() }
        defer { run.cancel() }
        #expect(await Self.waitUntil { store.isConnected })
        await store.send(text: "echo hi")
        #expect(await Self.waitUntil { Self.pendings(store.rows).count == 1 })
        await source.emitTerminalBlocks([
            TerminalCommandBlock(id: 0, command: "echo hi", output: "hi\n", exitCode: 0, isRunning: false),
        ])
        #expect(await Self.waitUntil {
            Self.pendings(store.rows).isEmpty && Self.blocks(store.rows).count == 1
        })
    }

    @Test("a terminal session never advertises more history (block paging unimplemented)")
    @MainActor func terminalNeverPagesHistory() async {
        let source = FixtureChatEventSource(
            terminalBacklog: [TerminalCommandBlock(id: 0, command: "ls", output: "a\n", exitCode: 0, isRunning: false)],
            terminalHasMore: true
        )
        let store = Self.makeStore(source)
        let run = Task { await store.run() }
        defer { run.cancel() }
        #expect(await Self.waitUntil { store.hasLoadedInitialHistory })
        // Even though the producer reports hasMore, the store forces it off so
        // loadOlder never fires / sets a wrong truncated state for terminals.
        #expect(store.hasMoreHistory == false)
    }

    @Test("terminal history seeds command-block rows in order")
    @MainActor func historySeedsRows() async {
        let source = FixtureChatEventSource(terminalBacklog: [
            TerminalCommandBlock(id: 0, command: "ls", output: "a\n", exitCode: 0, isRunning: false),
            TerminalCommandBlock(id: 1, command: "pwd", output: "/tmp\n", exitCode: 0, isRunning: false),
        ])
        let store = Self.makeStore(source)
        let run = Task { await store.run() }
        defer { run.cancel() }
        #expect(await Self.waitUntil { Self.blocks(store.rows).count == 2 })
        #expect(Self.blocks(store.rows).map(\.command) == ["ls", "pwd"])
    }

    @Test("a terminalBlocks event appends a new block and updates an existing one by id")
    @MainActor func upsertByID() async {
        let source = FixtureChatEventSource(terminalBacklog: [
            TerminalCommandBlock(id: 0, command: "make", output: "step1", exitCode: nil, isRunning: true),
        ])
        let store = Self.makeStore(source)
        let run = Task { await store.run() }
        defer { run.cancel() }
        #expect(await Self.waitUntil { store.isConnected && Self.blocks(store.rows).count == 1 })
        // New id -> appended.
        await source.emitTerminalBlocks([
            TerminalCommandBlock(id: 1, command: "test", output: "", exitCode: nil, isRunning: true),
        ])
        #expect(await Self.waitUntil { Self.blocks(store.rows).count == 2 })
        // Existing id -> replaced in place (output grew, finished).
        await source.emitTerminalBlocks([
            TerminalCommandBlock(id: 0, command: "make", output: "step1\nstep2\n", exitCode: 0, isRunning: false),
        ])
        #expect(await Self.waitUntil {
            let b = Self.blocks(store.rows)
            return b.count == 2 && b[0].exitCode == 0 && b[0].output == "step1\nstep2\n"
        })
    }
}
