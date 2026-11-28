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
}
