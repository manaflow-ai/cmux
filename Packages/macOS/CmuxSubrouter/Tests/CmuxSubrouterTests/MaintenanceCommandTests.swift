import Testing
@testable import CmuxSubrouter

@Suite struct MaintenanceCommandTests {
    @Test func buildsPerProviderVerbs() {
        #expect(SubrouterMaintenanceCommand.addAccount(provider: .codex) == "sr add")
        #expect(SubrouterMaintenanceCommand.addAccount(provider: .claude) == "sr claude add")
        #expect(SubrouterMaintenanceCommand.addAccount(provider: SubrouterProvider(rawValue: "gemini")) == nil)
        #expect(
            SubrouterMaintenanceCommand.removeAccount(provider: .codex, accountID: "a@b.com")
                == "sr remove 'a@b.com'"
        )
        #expect(
            SubrouterMaintenanceCommand.removeAccount(provider: .claude, accountID: "work")
                == "sr claude remove 'work'"
        )
        #expect(SubrouterMaintenanceCommand.signIn(provider: .codex, accountID: "a@b.com") == "sr add")
        #expect(
            SubrouterMaintenanceCommand.signIn(provider: .claude, accountID: "work")
                == "sr claude add 'work'"
        )
    }

    @Test func quotesHostileAccountIDs() {
        // A profile name with quotes/metacharacters must stay one shell word.
        #expect(SubrouterMaintenanceCommand.shellQuoted("a'b; rm -rf ~") == "'a'\\''b; rm -rf ~'")
        #expect(
            SubrouterMaintenanceCommand.removeAccount(provider: .claude, accountID: "a'b")
                == "sr claude remove 'a'\\''b'"
        )
    }
}
