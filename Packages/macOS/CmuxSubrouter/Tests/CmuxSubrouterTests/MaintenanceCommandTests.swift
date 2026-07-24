import Testing
@testable import CmuxSubrouter

@Suite struct MaintenanceCommandTests {
    @Test func buildsPerProviderVerbs() {
        #expect(SubrouterMaintenanceCommand.addAccount(provider: .codex) == "cmux sr add")
        #expect(SubrouterMaintenanceCommand.addAccount(provider: .claude) == "cmux sr claude add")
        #expect(SubrouterMaintenanceCommand.addAccount(provider: SubrouterProvider(rawValue: "gemini")) == nil)
        #expect(
            SubrouterMaintenanceCommand.removeAccount(provider: .codex, accountID: "a@b.com")
                == "cmux sr remove 'a@b.com'"
        )
        #expect(
            SubrouterMaintenanceCommand.removeAccount(provider: .claude, accountID: "work")
                == "cmux sr claude remove 'work'"
        )
        #expect(SubrouterMaintenanceCommand.signIn(provider: .codex, accountID: "a@b.com") == "cmux sr add")
        #expect(
            SubrouterMaintenanceCommand.signIn(provider: .claude, accountID: "work")
                == "cmux sr claude add 'work'"
        )
    }

    @Test func remoteAddChainsTheServerUpload() {
        #expect(
            SubrouterMaintenanceCommand.addAccount(provider: .codex, serverName: "cmux-mac-mini")
                == "cmux sr add && cmux sr server sync 'cmux-mac-mini' --yes"
        )
        #expect(
            SubrouterMaintenanceCommand.addAccount(provider: .claude, serverName: "cmux-mac-mini")
                == "cmux sr claude add && cmux sr claude push"
        )
        #expect(
            SubrouterMaintenanceCommand.addAccount(
                provider: SubrouterProvider(rawValue: "gemini"),
                serverName: "cmux-mac-mini"
            ) == nil
        )
    }

    @Test func quotesHostileAccountIDs() {
        // A profile name with quotes/metacharacters must stay one shell word.
        #expect(SubrouterMaintenanceCommand.shellQuoted("a'b; rm -rf ~") == "'a'\\''b; rm -rf ~'")
        #expect(
            SubrouterMaintenanceCommand.removeAccount(provider: .claude, accountID: "a'b")
                == "cmux sr claude remove 'a'\\''b'"
        )
    }
}
