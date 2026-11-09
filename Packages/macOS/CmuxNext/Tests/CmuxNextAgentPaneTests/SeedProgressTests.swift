import CmuxNextCloud
import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `cmux link seed push`'s progress lines (cmux-tui `link/seed_cli.rs`) as the clone row's fields.
struct SeedProgressTests {

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
