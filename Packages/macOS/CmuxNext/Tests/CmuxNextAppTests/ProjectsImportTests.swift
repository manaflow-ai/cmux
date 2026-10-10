import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The app relays acpmux's chat index into the project store
/// (plans/cmux-next/projects.md section 3): one complete `project.observe`
/// per harness whose project set changed, and nothing for one that did not.
@Suite struct ProjectsImportTests {
    func chat(_ id: String, _ harness: String, _ cwd: String?, _ ms: Int) -> AcpmuxChat {
        AcpmuxChat(id: id, sessionID: id, harness: harness, cwd: cwd,
                   updatedAt: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    @Test func groupsEachHarnessCwdsWithTheirNewestUse() {
        let chats = [
            chat("1", "claude", "/Users/me/src/app", 1_000),
            chat("2", "claude", "/Users/me/src/app", 3_000),
            chat("3", "claude", "/Users/me/src/api", 2_000),
            chat("4", "codex", "/Users/me/src/app", 5_000),
            chat("5", "codex", nil, 6_000),
            chat("6", "codex", "relative/dir", 7_000),
            chat("7", "codex", "", 8_000),
        ]
        let batches = ProjectsImport.batches(chats, sent: [:])
        #expect(batches.map(\.source) == ["claude", "codex"])
        #expect(batches[0].entries == [.init(path: "/Users/me/src/api", lastUsedMs: 2_000),
                                       .init(path: "/Users/me/src/app", lastUsedMs: 3_000)])
        #expect(batches[1].entries == [.init(path: "/Users/me/src/app", lastUsedMs: 5_000)])
    }

    @Test func aHarnessWhoseSetDidNotChangeSendsNothing() {
        let first = ProjectsImport.batches([chat("1", "claude", "/a", 1), chat("2", "codex", "/b", 1)], sent: [:])
        let sent = Dictionary(uniqueKeysWithValues: first.map { ($0.source, $0.fingerprint) })
        let again = ProjectsImport.batches([chat("1", "claude", "/a", 1), chat("2", "codex", "/b", 9)], sent: sent)
        #expect(again.map(\.source) == ["codex"])
    }

    @Test func aHarnessWhoseLastChatWentSendsAnEmptyCompleteList() {
        let first = ProjectsImport.batches([chat("1", "claude", "/a", 1)], sent: [:])
        let sent = Dictionary(uniqueKeysWithValues: first.map { ($0.source, $0.fingerprint) })
        let gone = ProjectsImport.batches([], sent: sent)
        #expect(gone.map(\.source) == ["claude"])
        #expect(gone[0].entries.isEmpty)
    }

    @Test func theObserveParamsCarryDecimalTimes() {
        let batch = ProjectsImport.batches([chat("1", "claude", "/a", 1_790_901_089_000)], sent: [:])[0]
        #expect(batch.entriesJSON == [.object(["path": .string("/a"), "last_used_ms": .string("1790901089000")])])
    }
}
