@testable import CmuxMobileAgentChat
import CmuxMobileArtifacts
import Foundation
import Testing

@MainActor
@Suite struct SubagentAndArtifactTests {
    func historyStore() async -> AgentChatStore {
        let mock = MockAgentSession(
            summary: AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "/Users/me/cmux",
                                         workspaceTitle: "cmux", macName: "Studio", branch: "main"),
            sleep: { _ in await Task.yield() }
        )
        let store = AgentChatStore(source: mock)
        while store.turns.count < 2 || store.turns.last?.status != .completed { await Task.yield() }
        return store
    }

    @Test func subagentsFoldOutOfTheParentTranscript() async throws {
        let store = await historyStore()
        #expect(store.subagents.map(\.id) == ["sa-webrtc", "sa-wg", "sa-tests", "sa-relay"])
        #expect(store.subagents.allSatisfy { $0.state == .completed })
        let relay = try #require(store.subagent("sa-relay"))
        #expect(relay.parent == "sa-wg")
        let turn = try #require(store.turns.last)
        let rows = turn.rows
        // The spawn tool calls draw as one subagent group, not as tool rows.
        #expect(rows.contains { if case .subagents(_, let ids) = $0 { ids == ["sa-webrtc", "sa-wg", "sa-tests"] } else { false } })
        #expect(!rows.contains { if case .tool(let call) = $0 { call.id.hasPrefix("tu-") } else { false } })
        // The nested subagent is a group inside its parent's own transcript.
        let wireGuard = try #require(store.subagent("sa-wg"))
        #expect(wireGuard.asTurn.rows.contains { if case .subagents(_, ["sa-relay"]) = $0 { true } else { false } })
        #expect(wireGuard.action == "Read wg.rs")
    }

    @Test func collectsEveryReferenceInTheSession() async throws {
        let store = await historyStore()
        let collected = SessionArtifacts.collect(turns: store.turns, subagents: store.subagents, cwd: store.summary.cwd)
        let byReference = Dictionary(uniqueKeysWithValues: collected.artifacts.map { ($0.reference, $0) })
        // Edits, shell output, answer links and paths, reads inside subagents, attachments.
        #expect(byReference["cmux-next-ios/verify/transport-report.html"]?.kind == .html)
        #expect(byReference["cmux-next-ios/verify/transport-report.html"]?.detail?.hasPrefix("Created") == true)
        #expect(byReference["cmux-next-ios/verify/screenshots/terminal.png"]?.kind == .image)
        #expect(byReference["cmux-next-ios/verify/recordings/demo.mp4"]?.kind == .video)
        #expect(byReference["cmux-next-ios/verify/transport-report.pdf"]?.kind == .pdf)
        #expect(byReference["https://www.rfc-editor.org/rfc/rfc8445"]?.kind == .link)
        #expect(byReference["cmux-next-ios/rust/cmux-mobile-link/src/wg.rs"]?.detail == "Read · WireGuard dialer")
        #expect(byReference["cmux-next-ios/rust/cmux-mobile-link/src/dial.rs"]?.line == 88)
        #expect(byReference["cmux-next-ios/verify/relay-rtt.csv"] != nil)
        let attachment = try #require(byReference["Attachments/connection-settings.png"])
        #expect(attachment.detail == "Attached")
        #if canImport(UIKit)
        guard case .image? = collected.inline[attachment.reference] else { Issue.record("attachment not inline"); return }
        #endif
    }

    /// Round 2: links from the answer came before the files the agent edited.
    /// The browser lists by `order`, highest first.
    @Test func strongestReferencesComeFirst() async throws {
        let store = await historyStore()
        let collected = SessionArtifacts.collect(turns: store.turns, subagents: store.subagents, cwd: store.summary.cwd)
        let shown = collected.artifacts.sorted { $0.order > $1.order }
        func rank(_ artifact: TerminalArtifact) -> Int {
            let detail = artifact.detail ?? ""
            if artifact.kind == .link { return 3 }
            if detail.hasPrefix("Edited") || detail.hasPrefix("Created") || detail.hasPrefix("Deleted")
                || detail.hasPrefix("Moved") || detail == "Attached" { return 0 }
            if detail.hasPrefix("Read") || detail.hasPrefix("Fetched") { return 1 }
            return 2
        }
        let ranks = shown.map(rank)
        #expect(ranks == ranks.sorted())
        #expect(shown.first.map(rank) == 0)
        #expect(shown.contains { $0.kind == .link })
    }

    @Test func absolutePathsAndRelativeReferences() {
        let collector = SessionArtifacts.Collector(cwd: "/Users/me/cmux")
        #expect(collector.normalize("/Users/me/cmux/src/a.swift") == "src/a.swift")
        #expect(collector.normalize("./b.rs") == "b.rs")
        #expect(LinkFileArtifactSource.absolutePath("src/a.swift", base: "/Users/me/cmux") == "/Users/me/cmux/src/a.swift")
        #expect(LinkFileArtifactSource.absolutePath("/etc/../tmp/x", base: nil) == "/tmp/x")
        #expect(LinkFileArtifactSource.absolutePath("~/x", base: "/Users/me") == nil)
        #expect(LinkFileArtifactSource.absolutePath("x", base: "~/cmux") == nil)
        // A live chat's folder is the workspace's display path: an edit's
        // absolute path and the answer's relative mention are one file.
        let display = SessionArtifacts.Collector(cwd: "~/work/demo")
        #expect(display.normalize("/Users/cmux/work/demo/README.md") == "README.md")
        #expect(display.normalize("/opt/work/demo/README.md") == "/opt/work/demo/README.md")
    }

    @Test func mockCheckpointsRestoreAndHandoff() async throws {
        let store = await historyStore()
        let source = store.source
        let checkpoints = try await source.checkpoints()
        #expect(checkpoints.first?.id == "cp-h2-after")
        let summary = try await source.restore(try #require(checkpoints.first { $0.id == "cp-h2" }))
        #expect(summary == "Restored 3 files")
        #expect(try await source.checkpoints().first?.caption?.hasPrefix("Before restoring") == true)
        let targets = try await source.handoffTargets()
        #expect(!targets.contains { $0.id == "claude" })
        #expect(targets.first { $0.id == "gemini" }?.unavailableReason != nil)
        var draft = try await source.prepareHandoff(to: try #require(targets.first))
        draft.checkpointReference = "stash@{0}"
        let receipt = try await source.startHandoff(draft)
        #expect(receipt.targetName == "Codex")
    }
}

@Suite struct LinkFileContentTests {
    @Test func decodesByKind() throws {
        let text = try LinkFileArtifactSource.content(for: TerminalArtifact(reference: "a.md", kind: .markdown), data: Data("# Hi".utf8))
        guard case .text("# Hi") = text else { Issue.record("text"); return }
        // Not text after all: a local copy for Quick Look (or Share), named as on the Mac.
        let binary = try LinkFileArtifactSource.content(for: TerminalArtifact(reference: "a.txt", kind: .text), data: Data([0xff, 0xfe, 0x00, 0xd8]))
        guard case .quickLook(let url) = binary else { Issue.record("quickLook"); return }
        #expect(url.lastPathComponent == "a.txt")
    }
}
