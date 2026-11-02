import CmuxNextCloud
import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `cmux link seed push`'s progress lines (cmux-tui `link/seed_cli.rs`) as the clone row's fields.
struct SeedProgressTests {
    @Test func readsTheSeedsCopysAndFallbacksLinesAndNothingElse() throws {
        let upload = try #require(SeedProgress.parse(#"{"progress":{"phase":"upload","bytes_done":5,"bytes_total":9}}"#))
        #expect(upload == SeedProgress(phase: "upload", bytesDone: 5, bytesTotal: 9))
        let copy = try #require(SeedProgress.parse(#"{"progress":{"files_done":1,"files_total":3,"bytes_done":4,"bytes_total":8}}"#))
        #expect(copy.phase == "copy" && copy.filesDone == 1 && copy.filesTotal == 3)
        let fallback = try #require(SeedProgress.parse(#"{"progress":{"phase":"copy","fallback_code":"seed.needs_github","install_url":"https://github.com/apps/cmux"}}"#))
        #expect(fallback.fallbackCode == "seed.needs_github" && fallback.installURL == "https://github.com/apps/cmux")
        #expect(SeedProgress.parse("warning: something") == nil)
        #expect(SeedProgress.parse(#"{"ok":true}"#) == nil)
    }

    @Test func throttlesButAPhaseChangeAlwaysGoesAndAFallbackStaysOnTheCopy() {
        let seen = Mutex<[SeedProgress]>([])
        let read = SeedProgress.reader { value in seen.withLock { $0.append(value) } }
        read(#"{"progress":{"phase":"upload","bytes_done":1,"bytes_total":9}}"#)
        read(#"{"progress":{"phase":"upload","bytes_done":2,"bytes_total":9}}"#)
        read(#"{"progress":{"phase":"copy","fallback_code":"not_git"}}"#)
        read(#"{"progress":{"files_done":1,"files_total":2}}"#)
        let values = seen.withLock { $0 }
        #expect(values.map(\.phase) == ["upload", "copy"])
        #expect(values.last?.fallbackCode == "not_git")
    }

    @MainActor @Test func feedHandsEachValueOverWhileItRunsThenTheAnswer() async throws {
        var phases: [String] = []
        let answer = try await SeedProgress.feed({ line in
            line(#"{"progress":{"phase":"clone","objects":1,"objects_total":2}}"#)
            line(#"{"progress":{"phase":"checkout"}}"#)
            return 7
        }) { phases.append($0.phase) }
        #expect(answer == 7)
        #expect(phases.last == "checkout")
    }

    @Test func theCloneRowFieldsMatchThePagesNames() {
        let fields = AgentPaneCloudStart.fields(SeedProgress(phase: "copy", bytesDone: 3, bytesTotal: 4, filesDone: 1, filesTotal: 2,
                                                             fallbackCode: "seed.needs_github", installURL: "https://x.test"))
        #expect(fields["fallback"] == .string("seed.needs_github"))
        #expect(fields["install_url"] == .string("https://x.test"))
        #expect(fields["progress"] == .object(["received_bytes": .number(3), "bytes_total": .number(4),
                                               "files_done": .number(1), "files_total": .number(2)]))
    }
}
