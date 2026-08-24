import Testing
@testable import CmuxSubrouter

@Suite struct MaintenanceCommandTests {
    @Test func buildsPerProviderVerbs() {
        #expect(
            SubrouterMaintenanceCommand.addAccount(provider: .codex)
                == "SUBROUTER_CODEX_SERVER=local cmux sr add"
        )
        #expect(
            SubrouterMaintenanceCommand.addAccount(provider: .claude)
                == "SUBROUTER_CODEX_SERVER=local cmux sr claude add"
        )
        #expect(SubrouterMaintenanceCommand.addAccount(provider: SubrouterProvider(rawValue: "gemini")) == nil)
        #expect(
            SubrouterMaintenanceCommand.removeAccount(provider: .codex, accountID: "a@b.com")
                == "SUBROUTER_CODEX_SERVER=local cmux sr remove 'a@b.com'"
        )
        #expect(
            SubrouterMaintenanceCommand.removeAccount(provider: .claude, accountID: "work")
                == "SUBROUTER_CODEX_SERVER=local cmux sr claude remove 'work'"
        )
        #expect(
            SubrouterMaintenanceCommand.signIn(provider: .codex, accountID: "a@b.com")
                == "SUBROUTER_CODEX_SERVER=local cmux sr add"
        )
        #expect(
            SubrouterMaintenanceCommand.signIn(provider: .claude, accountID: "work")
                == nil
        )
    }

    @Test func connectServerIsAPreTypedTemplate() {
        #expect(
            SubrouterMaintenanceCommand.connectServer
                == "cmux sr server add <name> --url <url> --default"
        )
    }

    @Test func addPinsTheRequestedDestinationWithoutMutatingRegistry() {
        #expect(
            SubrouterMaintenanceCommand.addAccount(provider: .codex)
                == "SUBROUTER_CODEX_SERVER=local cmux sr add"
        )
        #expect(
            SubrouterMaintenanceCommand.addAccount(
                provider: .codex,
                target: .server(name: "cmux-mac-mini")
            )
                == "SUBROUTER_CODEX_SERVER='cmux-mac-mini' cmux sr add"
        )
        #expect(
            SubrouterMaintenanceCommand.addAccount(
                provider: .claude,
                target: .server(name: "cmux-mac-mini")
            )
                == "SUBROUTER_CODEX_SERVER='cmux-mac-mini' cmux sr claude add"
        )
        #expect(
            SubrouterMaintenanceCommand.addAccount(
                provider: SubrouterProvider(rawValue: "gemini"),
                target: .server(name: "cmux-mac-mini")
            ) == nil
        )
    }

    @Test func quotesHostileAccountIDs() {
        // A profile name with quotes/metacharacters must stay one shell word.
        #expect(SubrouterMaintenanceCommand.shellQuoted("a'b; rm -rf ~") == "'a'\\''b; rm -rf ~'")
        #expect(
            SubrouterMaintenanceCommand.removeAccount(provider: .claude, accountID: "a'b")
                == "SUBROUTER_CODEX_SERVER=local cmux sr claude remove 'a'\\''b'"
        )
        #expect(
            SubrouterMaintenanceCommand.signIn(
                provider: .codex,
                accountID: "a@b.com",
                target: .server(name: "team")
            ) == "SUBROUTER_CODEX_SERVER='team' cmux sr add"
        )
    }

    @Test func configurationOnlyProducesNamedRemoteTarget() throws {
        let local = SubrouterConfiguration(isEnabled: true)
        #expect(local.accountTarget == .local)

        let remoteEndpoint = try #require(
            SubrouterEndpoint(configurationString: "http://server.example:31415")
        )
        let namedRemote = SubrouterConfiguration(
            isEnabled: true,
            endpoint: remoteEndpoint,
            serverName: "team"
        )
        #expect(namedRemote.accountTarget == .server(name: "team"))

        // An explicit URL without a registry name is safe for monitoring but
        // cannot safely select a mutation destination.
        let unnamedRemote = SubrouterConfiguration(isEnabled: true, endpoint: remoteEndpoint)
        #expect(unnamedRemote.accountTarget == nil)
    }
}
