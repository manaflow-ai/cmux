import CmuxNextAgentPane
import CmuxNextDaemon
import Testing

struct AcpmuxChatProjectsTests {
    @Test func batchesAreCompleteSortedAndUnchangedSourcesAreNotResent() throws {
        let projects = AcpmuxChatProjects(ready: true, enabled: true, projects: [
            .init(harness: "codex", path: "/src/z", lastUsedMs: 12),
            .init(harness: "claude-code", path: "/src/app", lastUsedMs: 8),
            .init(harness: "codex", path: "/src/a", lastUsedMs: 10),
        ])
        let batches = projects.batches(sent: [:])
        #expect(batches.map(\.source) == ["claude-code", "codex"])
        let codex = try #require(batches.last)
        #expect(codex.entries.map(\.path) == ["/src/a", "/src/z"])
        #expect(codex.entriesJSON == [
            .object(["path": .string("/src/a"), "last_used_ms": .string("10")]),
            .object(["path": .string("/src/z"), "last_used_ms": .string("12")]),
        ])
        let sent = Dictionary(uniqueKeysWithValues: batches.map { ($0.source, $0.fingerprint) })
        #expect(projects.batches(sent: sent).isEmpty)
        let cleared = AcpmuxChatProjects(ready: true, enabled: true, projects: []).batches(sent: sent)
        #expect(cleared.map(\.source) == ["claude-code", "codex"])
        #expect(cleared.allSatisfy { $0.entries.isEmpty })
    }

    @Test(arguments: [(false, true), (true, false), (false, false)])
    func incompleteOrDisabledIndexDoesNotClearExistingSources(_ ready: Bool, _ enabled: Bool) {
        let projects = AcpmuxChatProjects(ready: ready, enabled: enabled, projects: [])
        #expect(projects.batches(sent: ["codex": 17]).isEmpty)
    }

    @Test func newerChatChangesItsHarnessBatch() {
        let old = AcpmuxChatProjects(ready: true, enabled: true, projects: [
            .init(harness: "codex", path: "/src/app", lastUsedMs: 10),
        ])
        let sent = Dictionary(uniqueKeysWithValues: old.batches(sent: [:]).map { ($0.source, $0.fingerprint) })
        let newer = AcpmuxChatProjects(ready: true, enabled: true, projects: [
            .init(harness: "codex", path: "/src/app", lastUsedMs: 11),
        ])
        #expect(newer.batches(sent: sent).map(\.source) == ["codex"])
    }
}
