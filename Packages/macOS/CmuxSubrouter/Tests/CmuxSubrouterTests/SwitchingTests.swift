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
        // The post-switch refresh never pays the whole-history sessions
        // transfer: nothing after a switch reads sessions, and pending
        // state must not wait on that download.
        #expect(await client.sessionsCallCount == 0)
        #expect(store.snapshot.activeAccount(for: .codex)?.id == "other@example.com")
        #expect(store.pendingSwitch == nil)
        #expect(store.lastSwitchError == nil)
    }

    @Test func preflightRefreshGuardsAgainstStaleRegistry() async throws {
        let client = FakeSubrouterClient()
        let switcher = FakeAccountSwitcher()
        let store = makeStore(client: client, switcher: switcher)
        // Simulates `sr server use <remote>` landing after the store's
        // cached configuration was composed: the preflight re-applies the
        // registry, and the switch must route to the remote endpoint —
        // never the local sr CLI — based on the current selection.
        store.configurationPreflight = { @MainActor in
            store.updateConfiguration(
                SubrouterConfiguration(
                    isEnabled: true,
                    endpoint: SubrouterEndpoint(configurationString: "http://cmux-mac-mini:31415")!,
                    serverName: "cmux-mac-mini",
                    tuning: SubrouterPollTuning(jitterFraction: 0)
                )
            )
        }

        try await store.switchAccount(provider: .codex, accountID: "dev@example.com")
        #expect(await switcher.invocations.isEmpty)
        #expect(await client.switchCallCount == 1)
        #expect(await client.lastEndpoint?.baseURL.host() == "cmux-mac-mini")
    }

    @Test func disablingMidSwitchSkipsDaemonFollowUp() async throws {
        let client = FakeSubrouterClient()
        let switcher = FakeAccountSwitcher()
        let store = makeStore(client: client, switcher: switcher)
        // Disable the integration while the (up to 30 s) sr call is in
        // flight: the on-disk switch cannot be undone, but no reload or
        // refresh may reach the daemon afterwards.
        await switcher.setOnSwitch { @MainActor in
            store.updateConfiguration(
                SubrouterConfiguration(isEnabled: false, tuning: SubrouterPollTuning(jitterFraction: 0))
            )
        }

        try await store.switchAccount(provider: .codex, accountID: "dev@example.com")

        #expect(await switcher.invocations.count == 1)
        #expect(await client.totalFetchCallCount == 0)
        #expect(store.pendingSwitch == nil)
    }

    @Test func endpointChangeMidSwitchSkipsDaemonFollowUp() async throws {
        let client = FakeSubrouterClient()
        let switcher = FakeAccountSwitcher()
        let store = makeStore(client: client, switcher: switcher)
        // Repointing the endpoint mid-switch must not send the post-switch
        // reload to a daemon the pre-switch guards never validated.
        await switcher.setOnSwitch { @MainActor in
            store.updateConfiguration(
                SubrouterConfiguration(
                    isEnabled: true,
                    endpoint: SubrouterEndpoint(configurationString: "http://127.0.0.1:9999")!,
                    tuning: SubrouterPollTuning(jitterFraction: 0)
                )
            )
        }

        try await store.switchAccount(provider: .codex, accountID: "dev@example.com")

        #expect(await client.reloadCallCount == 0)
        #expect(store.pendingSwitch == nil)
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
        await switcher.setError(.commandFailed)
        let store = makeStore(client: client, switcher: switcher)

        await #expect(throws: SubrouterSwitchError.commandFailed) {
            try await store.switchAccount(provider: .codex, accountID: "x")
        }
        #expect(store.lastSwitchError == .commandFailed)
        #expect(store.pendingSwitch == nil)
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
        // The follow-up refresh (and its health probe) also fails: the
        // daemon really is down.
        await client.setHealthResult(.failure(.unreachable(description: "daemon down")))
        await client.setUsageResult(.failure(.unreachable(description: "daemon down")))
        let switcher = FakeAccountSwitcher()
        let store = makeStore(client: client, switcher: switcher)

        // The on-disk switch landed, so no error is thrown.
        try await store.switchAccount(provider: .codex, accountID: "dev@example.com")
        #expect(store.lastSwitchError == nil)
        #expect(store.snapshot.lastErrorDescription == "The subrouter daemon could not be reached.")
        #expect(store.snapshot.daemonState == .unreachable(consecutiveFailures: 1))
    }

    private func makeRemoteStore(
        client: FakeSubrouterClient,
        switcher: FakeAccountSwitcher
    ) -> SubrouterStore {
        SubrouterStore(
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
    }

    @Test func remoteSwitchCallsEndpointThenRefreshesWithoutReload() async throws {
        let client = FakeSubrouterClient()
        await client.setUsageResult(.success([
            SubrouterAccountUsageStatus(id: "other@example.com", provider: .codex, isActive: true),
        ]))
        let switcher = FakeAccountSwitcher()
        let store = makeRemoteStore(client: client, switcher: switcher)

        try await store.switchAccount(provider: .codex, accountID: "other@example.com")

        // The sr CLI never runs against a remote server; the daemon's
        // switch-account endpoint is the whole mutation.
        #expect(await switcher.invocations.isEmpty)
        #expect(await client.switchCallCount == 1)
        let request = await client.lastSwitchRequest
        #expect(request?.provider == .codex)
        #expect(request?.accountID == "other@example.com")
        // reload-accounts is loopback-only and the endpoint invalidates the
        // server's usage cache itself — only the fresh refresh follows.
        #expect(await client.reloadCallCount == 0)
        #expect(await client.usageCallCount == 1)
        #expect(await client.sessionsCallCount == 0)
        #expect(store.snapshot.activeAccount(for: .codex)?.id == "other@example.com")
        #expect(store.pendingSwitch == nil)
        #expect(store.lastSwitchError == nil)
    }

    @Test func remoteServerWithoutSwitchEndpointSurfacesUpgradeError() async {
        let client = FakeSubrouterClient()
        // Older daemons route unknown /_subrouter/ paths to a 404 catch-all.
        await client.setSwitchResult(.failure(.httpStatus(code: 404, description: "")))
        let switcher = FakeAccountSwitcher()
        let store = makeRemoteStore(client: client, switcher: switcher)

        await #expect(throws: SubrouterSwitchError.remoteServerManagesSelection(serverName: "cmux-mac-mini")) {
            try await store.switchAccount(provider: .codex, accountID: "dev@example.com")
        }
        #expect(store.lastSwitchError == .remoteServerManagesSelection(serverName: "cmux-mac-mini"))
        #expect(await switcher.invocations.isEmpty)
        #expect(store.pendingSwitch == nil)
    }

    @Test func remoteSwitchRejectionSurfacesAsCommandFailed() async {
        let client = FakeSubrouterClient()
        // 422: the daemon is healthy but rejected the switch (unknown
        // account, refresh failure). Only the status code crosses the
        // client boundary.
        await client.setSwitchResult(.failure(.httpStatus(code: 422, description: "")))
        let switcher = FakeAccountSwitcher()
        let store = makeRemoteStore(client: client, switcher: switcher)

        await #expect(throws: SubrouterSwitchError.self) {
            try await store.switchAccount(provider: .codex, accountID: "nope@example.com")
        }
        guard case .commandFailed = store.lastSwitchError else {
            Issue.record("lastSwitchError = \(String(describing: store.lastSwitchError))")
            return
        }
        // No follow-up refresh after a failed switch.
        #expect(await client.usageCallCount == 0)
    }

    @Test func remoteSwitchOkFalseBodySurfacesAsCommandFailed() async {
        let client = FakeSubrouterClient()
        // A 2xx response whose body reports ok=false must not read as a
        // successful switch: no refresh, and the failure surfaces.
        await client.setSwitchResult(.success(SubrouterRemoteSwitchResult(ok: false)))
        let switcher = FakeAccountSwitcher()
        let store = makeRemoteStore(client: client, switcher: switcher)

        await #expect(throws: SubrouterSwitchError.self) {
            try await store.switchAccount(provider: .codex, accountID: "dev@example.com")
        }
        guard case .commandFailed = store.lastSwitchError else {
            Issue.record("lastSwitchError = \(String(describing: store.lastSwitchError))")
            return
        }
        #expect(await switcher.invocations.isEmpty)
        #expect(store.pendingSwitch == nil)
        #expect(await client.usageCallCount == 0)
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
        #expect(store.snapshot.lastErrorDescription == "Daemon reload reported failure")
    }

    @Test func reloadDaemonAccountsRefreshes() async throws {
        let client = FakeSubrouterClient()
        await client.setReloadResult(.success(SubrouterReloadResult(ok: true, accounts: 3, usageRefreshed: 2)))
        let store = makeStore(client: client, switcher: FakeAccountSwitcher())

        let result = try await store.reloadDaemonAccounts()
        #expect(result.accounts == 3)
        #expect(await client.usageCallCount == 1)
        // The reload verb's payload never reads sessions either.
        #expect(await client.sessionsCallCount == 0)
        #expect(store.snapshot.daemonState == .healthy)
    }

    @Test func remoteReloadIsRejectedBeforeNetworkCall() async throws {
        let client = FakeSubrouterClient()
        let remote = SubrouterEndpoint(configurationString: "http://team.example:31415")!
        let store = SubrouterStore(
            client: client,
            switcher: FakeAccountSwitcher(),
            clock: ManualSubrouterPollClock(),
            configuration: SubrouterConfiguration(
                isEnabled: true,
                endpoint: remote,
                serverName: "team",
                tuning: SubrouterPollTuning(jitterFraction: 0)
            )
        )

        await #expect(throws: SubrouterClientError.unsupported(
            description: "Account reload is only available for the local subrouter daemon."
        )) {
            try await store.reloadDaemonAccounts()
        }
        #expect(await client.reloadCallCount == 0)
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

    @Test func switchForcesTheSelectedServerEnvironment() async throws {
        let runner = FakeCommandRunner()
        runner.resultsByExecutable["sr"] = FakeCommandRunner.success()
        let switcher = SubrouterCommandSwitcher(commandRunner: runner, workingDirectory: "/tmp")

        try await switcher.switchAccount(
            provider: .codex,
            accountID: "dev@example.com",
            commandPath: nil,
            target: .local
        )
        #expect(runner.invocations.first?.environmentOverrides["SUBROUTER_CODEX_SERVER"] == "local")
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

    @Test func nonZeroExitUsesSanitizedError() async {
        let runner = FakeCommandRunner()
        runner.resultsByExecutable["sr"] = FakeCommandRunner.failure(stderr: "no account found matching \"x\"")
        let switcher = SubrouterCommandSwitcher(commandRunner: runner, workingDirectory: "/tmp")

        await #expect(throws: SubrouterSwitchError.commandFailed) {
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
