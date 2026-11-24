import Foundation
import Testing
import CmuxNextCompat

/// The star ask's rule (t3code's): never in the first five sent prompts, then until dismissed.
@Suite struct GitHubStarPromptCountTests {
    private static func defaults() -> UserDefaults {
        let name = "github-star-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func asksAfterFiveSentPromptsUntilDismissed() {
        let defaults = Self.defaults()
        let asks = (1...7).map { _ in GitHubStarPromptCount.countPrompt(in: defaults); return GitHubStarPromptCount.wanted(in: defaults) }
        #expect(asks == [false, false, false, false, false, true, true])
        GitHubStarPromptCount.dismiss(in: defaults)
        GitHubStarPromptCount.countPrompt(in: defaults)
        #expect(!GitHubStarPromptCount.wanted(in: defaults))
    }
}
