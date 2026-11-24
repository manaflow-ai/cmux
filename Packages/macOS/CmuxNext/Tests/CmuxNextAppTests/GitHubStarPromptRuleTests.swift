import Foundation
import Testing
import CmuxNextUpdater

/// The star ask's rule (t3code's): never in the first five sent prompts, then until dismissed.
@Suite struct GitHubStarPromptRuleTests {
    private static func defaults() -> UserDefaults {
        let name = "github-star-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func asksAfterFiveSentPromptsUntilDismissed() {
        let defaults = Self.defaults()
        let asks = (1...7).map { _ in GitHubStarPromptRule.countPrompt(in: defaults) }
        #expect(asks == [false, false, false, false, false, true, true])
        GitHubStarPromptRule.dismiss(in: defaults)
        #expect(!GitHubStarPromptRule.countPrompt(in: defaults))
        #expect(!GitHubStarPromptRule.stillWanted(in: defaults))
    }
}
