@testable import CmuxNextActions
@testable import CmuxNextDaemonService
import Testing

/// Step B of the four CLI-verb palette rows (cmux#46170; Leo, 2026-11-08: "Every conceivable possible aspect of the
/// app"): Remove Cloud Secret… names one index account and asks before it runs.
@MainActor
struct PaletteVerbActionsTests {
    @Test func secretValuesNameAnIndexAccount() {
        #expect(PaletteVerbActions.secretAccount("GITHUB_TOKEN")! == ("GITHUB_TOKEN", "*"), "a bare name is every repo's")
        #expect(PaletteVerbActions.secretAccount("*/GITHUB_TOKEN")! == ("GITHUB_TOKEN", "*"))
        #expect(PaletteVerbActions.secretAccount(" manaflow-ai/cmux/NPM_TOKEN ")! == ("NPM_TOKEN", "manaflow-ai/cmux"))
        #expect(PaletteVerbActions.secretAccount(nil) == nil)
        #expect(PaletteVerbActions.secretAccount("") == nil)
        #expect(PaletteVerbActions.secretAccount("not a name") == nil)
        #expect(PaletteVerbActions.secretAccount("/GITHUB_TOKEN") == nil, "an empty scope names no account")
        #expect(PaletteVerbActions.secretAccount("PATH") == nil, "a reserved name is never a secret")
    }

    @Test func removeSecretAsksFirstAndNamesTheSecret() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "cloud.secret.remove" })
        #expect(descriptor.isDestructive, "the registry hands an unconfirmed run to DestructiveConfirmation")
        let prompt = try #require(PaletteVerbActions.secretRemovePrompt(ActionInvocation(arguments: ["secret": .string("owner/repo/API_KEY")])))
        #expect(prompt.title.contains("owner/repo/API_KEY"))
        #expect(PaletteVerbActions.secretRemovePrompt(ActionInvocation(arguments: ["secret": .string("*/API_KEY")]))?.title.contains("*/") == false)
        #expect(PaletteVerbActions.secretRemovePrompt(ActionInvocation(arguments: [:])) == nil, "no secret: the handler refuses with why")
    }
}
