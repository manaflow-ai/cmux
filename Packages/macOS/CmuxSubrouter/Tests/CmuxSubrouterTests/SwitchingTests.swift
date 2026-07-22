import Foundation
import Testing
@testable import CmuxSubrouter

/// The single switch mutation path: sr invocation → daemon reload → fresh
/// refresh, plus every failure surface.
@MainActor
@Suite struct SwitchingTests {
    private func makeStore(
        client: FakeSubrouterClient,
        switcher: FakeAccountSwitcher,
        enabled: Bool = true,
        commandPath: String? = nil
    ) -> SubrouterStore {
        SubrouterStore(
            client: client,
            switcher: switcher,
            clock: ManualSubrouterPollClock(),
            configuration: SubrouterConfiguration(
                isEnabled: enabled,
                commandPath: commandPath,
                tuning: SubrouterPollTuning(jitterFraction: 0)
            )
        )
    }

    @Test func successfulSwitchRunsSrThenReloadThenRefresh() async throws {
        let client = FakeSubrouterClient()
        await client.setUsageResult(.success([
            SubrouterAccountUsageStatus(id: "other@example.com", provider: .codex, isActive: true),
        ]))
        let switcher = FakeAccountSwitcher()
        let store = makeStore(client: client, switcher: switcher, commandPath: "/opt/sr")

        try await store.switchAccount(provider: .codex, accountID: "other@example.com")

        let invocations = await switcher.invocations
        #expect(invocations == [
            FakeAccountSwitcher.Invocation(
                provider: .codex,
                accountID: "other@example.com",
                commandPath: "/opt/sr"
            ),
        ])
        #expect(await client.reloadCallCount == 1)
        #expect(await client.usageCallCount == 1)
        #expect(store.snapshot.activeAccount(for: .codex)?.id == "other@example.com")
        #expect(store.pendingSwitchAccountID == nil)
        #expect(store.lastSwitchError == nil)
    }

    @Test func switchWhileDisabledThrowsWithoutSideEffects() async {
        let client = FakeSubrouterClient()
        let switcher = FakeAccountSwitcher()
        let store = makeStore(client: client, switcher: switcher, enabled: false)

        await #expect(throws: SubrouterSwitchError.integrationDisabled) {
            try await store.switchAccount(provider: .codex, accountID: "x")
        }
        #expect(await switcher.invocations.isEmpty)
        #expect(await client.totalFetchCallCount == 0)
    }

    @Test func srFailureSurfacesAndSkipsReload() async {
        let client = FakeSubrouterClient()
        let switcher = FakeAccountSwitcher()
        await switcher.setError(.commandFailed(description: "no account found matching \"x\""))
        let store = makeStore(client: client, switcher: switcher)

        await #expect(throws: SubrouterSwitchError.commandFailed(description: "no account found matching \"x\"")) {
            try await store.switchAccount(provider: .codex, accountID: "x")
        }
        #expect(store.lastSwitchError == .commandFailed(description: "no account found matching \"x\""))
        #expect(store.pendingSwitchAccountID == nil)
        #expect(await client.reloadCallCount == 0)
    }

    @Test func srNotInstalledSurfacesCommandNotFound() async {
        let client = FakeSubrouterClient()
        let switcher = FakeAccountSwitcher()
        await switcher.setError(.commandNotFound)
        let store = makeStore(client: client, switcher: switcher)

        await #expect(throws: SubrouterSwitchError.commandNotFound) {
            try await store.switchAccount(provider: .claude, accountID: "work")
        }
        #expect(store.lastSwitchError == .commandNotFound)
    }

    @Test func reloadFailureAfterSwitchBecomesWarningNotError() async throws {
        let client = FakeSubrouterClient()
        await client.setReloadResult(.failure(.unreachable(description: "daemon down")))
        // The follow-up refresh also fails: daemon really is down.
        await client.setUsageResult(.failure(.unreachable(description: "daemon down")))
        let switcher = FakeAccountSwitcher()
        let store = makeStore(client: client, switcher: switcher)

        // The on-disk switch landed, so no error is thrown.
        try await store.switchAccount(provider: .codex, accountID: "dev@example.com")
        #expect(store.lastSwitchError == nil)
        #expect(store.snapshot.lastErrorDescription == "daemon down")
        #expect(store.snapshot.daemonState == .unreachable(consecutiveFailures: 1))
    }

    @Test func remoteServerEndpointRefusesGlobalSwitch() async {
        let client = FakeSubrouterClient()
        let switcher = FakeAccountSwitcher()
        let store = SubrouterStore(
            client: client,
            switcher: switcher,
            clock: ManualSubrouterPollClock(),
            configuration: SubrouterConfiguration(
                isEnabled: true,
                endpoint: SubrouterEndpoint(configurationString: "http://cmux-mac-mini:31415")!,
                serverName: "cmux-mac-mini",
                tuning: SubrouterPollTuning(jitterFraction: 0)
            )
        )

        // Remote servers assign accounts per session; sr switch refuses to
        // edit local state, so the store must fail before invoking sr.
        await #expect(throws: SubrouterSwitchError.remoteServerManagesSelection(serverName: "cmux-mac-mini")) {
            try await store.switchAccount(provider: .codex, accountID: "dev@example.com")
        }
        #expect(await switcher.invocations.isEmpty)
    }

    @Test func loopbackEndpointsAreNotRemote() {
        #expect(!SubrouterConfiguration(isEnabled: true).isRemoteEndpoint)
        let remote = SubrouterConfiguration(
            isEnabled: true,
            endpoint: SubrouterEndpoint(configurationString: "cmux-mac-mini:31415")!
        )
        #expect(remote.isRemoteEndpoint)
    }

    @Test func reloadReportingNotOKAfterSwitchBecomesWarning() async throws {
        let client = FakeSubrouterClient()
        await client.setReloadResult(.success(SubrouterReloadResult(ok: false, accounts: 0, usageRefreshed: 0)))
        let store = makeStore(client: client, switcher: FakeAccountSwitcher())

        // HTTP success with ok=false: the on-disk switch landed, so no throw,
        // but the failed hot reload surfaces as a snapshot warning.
        try await store.switchAccount(provider: .codex, accountID: "dev@example.com")
        #expect(store.lastSwitchError == nil)
        #expect(store.snapshot.lastErrorDescription == "daemon reload reported failure")
    }

    @Test func reloadDaemonAccountsRefreshes() async throws {
        let client = FakeSubrouterClient()
        await client.setReloadResult(.success(SubrouterReloadResult(ok: true, accounts: 3, usageRefreshed: 2)))
        let store = makeStore(client: client, switcher: FakeAccountSwitcher())

        let result = try await store.reloadDaemonAccounts()
        #expect(result.accounts == 3)
        #expect(await client.usageCallCount == 1)
        #expect(store.snapshot.daemonState == .healthy)
    }
}

/// The production switcher's binary resolution and argument shapes, driven
/// through a fake process runner.
@Suite struct SubrouterCommandSwitcherTests {
    @Test func codexSwitchArguments() throws {
        #expect(
            try SubrouterCommandSwitcher.switchArguments(provider: .codex, accountID: "dev@example.com")
                == ["switch", "dev@example.com"]
        )
    }

    @Test func claudeSwitchArguments() throws {
        #expect(
            try SubrouterCommandSwitcher.switchArguments(provider: .claude, accountID: "work")
                == ["claude", "switch", "work"]
        )
    }

    @Test func unknownProviderIsUnsupported() {
        #expect(throws: SubrouterSwitchError.switchUnsupported(provider: SubrouterProvider(rawValue: "gemini"))) {
            _ = try SubrouterCommandSwitcher.switchArguments(
                provider: SubrouterProvider(rawValue: "gemini"),
                accountID: "x"
            )
        }
    }

    @Test func explicitCommandPathIsUsedVerbatim() async throws {
        let runner = FakeCommandRunner()
        runner.resultsByExecutable["/opt/tools/sr"] = FakeCommandRunner.success()
        let switcher = SubrouterCommandSwitcher(commandRunner: runner, workingDirectory: "/tmp")

        try await switcher.switchAccount(
            provider: .codex,
            accountID: "dev@example.com",
            commandPath: "/opt/tools/sr"
        )
        #expect(runner.invocations.map(\.executable) == ["/opt/tools/sr"])
        #expect(runner.invocations[0].arguments == ["switch", "dev@example.com"])
    }

    @Test func tildeCommandPathExpandsToHomeDirectory() async throws {
        // Settings accepts `~/bin/subrouter`, but neither CommandRunner nor
        // /usr/bin/env expands a tilde — the switcher must resolve it.
        let expanded = ("~/bin/sr-tilde-test" as NSString).expandingTildeInPath
        let runner = FakeCommandRunner()
        runner.resultsByExecutable[expanded] = FakeCommandRunner.success()
        let switcher = SubrouterCommandSwitcher(commandRunner: runner, workingDirectory: "/tmp")

        try await switcher.switchAccount(
            provider: .codex,
            accountID: "dev@example.com",
            commandPath: "~/bin/sr-tilde-test"
        )
        #expect(runner.invocations.map(\.executable) == [expanded])
        #expect(expanded.hasPrefix("/"))
    }

    @Test func fallsBackFromSrToSubrouter() async throws {
        let runner = FakeCommandRunner()
        runner.resultsByExecutable["subrouter"] = FakeCommandRunner.success()
        let switcher = SubrouterCommandSwitcher(commandRunner: runner, workingDirectory: "/tmp")

        try await switcher.switchAccount(provider: .claude, accountID: "work", commandPath: nil)
        #expect(runner.invocations.map(\.executable) == ["sr", "subrouter"])
        #expect(runner.invocations[1].arguments == ["claude", "switch", "work"])
    }

    @Test func missingBinaryThrowsCommandNotFound() async {
        let runner = FakeCommandRunner()
        let switcher = SubrouterCommandSwitcher(commandRunner: runner, workingDirectory: "/tmp")

        await #expect(throws: SubrouterSwitchError.commandNotFound) {
            try await switcher.switchAccount(provider: .codex, accountID: "x", commandPath: nil)
        }
    }

    @Test func nonZeroExitCarriesStderr() async {
        let runner = FakeCommandRunner()
        runner.resultsByExecutable["sr"] = FakeCommandRunner.failure(stderr: "no account found matching \"x\"")
        let switcher = SubrouterCommandSwitcher(commandRunner: runner, workingDirectory: "/tmp")

        await #expect(throws: SubrouterSwitchError.commandFailed(description: "no account found matching \"x\"")) {
            try await switcher.switchAccount(provider: .codex, accountID: "x", commandPath: nil)
        }
    }

    @Test func timeoutThrowsCommandTimedOut() async {
        let runner = FakeCommandRunner()
        runner.resultsByExecutable["sr"] = FakeCommandRunner.timeout
        let switcher = SubrouterCommandSwitcher(commandRunner: runner, workingDirectory: "/tmp")

        await #expect(throws: SubrouterSwitchError.commandTimedOut) {
            try await switcher.switchAccount(provider: .codex, accountID: "x", commandPath: nil)
        }
    }
}
