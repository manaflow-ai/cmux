import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// The composer's Send while the foreground connection is being recovered:
/// a send that arrives with the dead client already retired waits for the
/// redial to install its replacement instead of failing on the spot, and a
/// paste that dies with `connectionClosed` starts that recovery itself.
@MainActor
@Suite struct ComposerSendReconnectWaitTests {
    private static let terminalID = RoutingHostRouter.terminalA

    /// Retire the live client the way `startConnectionRecovery` does once the
    /// redial phase begins: owner in `.redialing`, `remoteClient == nil`,
    /// `isRecoveringConnection == true`.
    private func retireClientForRecovery(
        _ store: MobileShellComposite
    ) throws -> MobileConnectionRecoveryOwner.Attempt {
        let attempt = try #require(store.connectionRecoveryOwner.begin(
            trigger: "test",
            sourceConnectionGeneration: store.connectionGeneration,
            probing: false
        ))
        store.retireRemoteClientForConnectionRecovery()
        store.applyConnectionRecoveryOwnerState()
        #expect(store.remoteClient == nil)
        #expect(store.isRecoveringConnection)
        return attempt
    }

    @Test func sendDuringRecoveryWaitsForTheReplacementClient() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: Self.terminalID))
        store.terminalInputText = "hello"
        _ = try retireClientForRecovery(store)

        let submit = Task { await store.submitComposer() }
        #expect(try await pollUntil {
            store.terminalSendStatus(forTerminalID: Self.terminalID) == .sending
        })
        #expect(await router.recordedPastes().isEmpty)
        #expect(store.terminalSendStatus(forTerminalID: Self.terminalID) == .sending)

        let replacementRouter = RoutingHostRouter()
        try installFreshRemoteClient(on: store, router: replacementRouter)

        #expect(await submit.value)
        let pastes = await replacementRouter.recordedPastes()
        #expect(pastes.map(\.text) == ["hello"])
        #expect(pastes.map(\.surfaceID) == [Self.terminalID])
        #expect(await router.recordedPastes().isEmpty)
        #expect(store.terminalSendStatus(forTerminalID: Self.terminalID) == .sent)
        #expect(store.terminalInputText == "")
    }

    @Test func sendWithoutClientAndNoRecoveryFailsImmediately() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: Self.terminalID))
        store.terminalInputText = "hello"
        store.remoteClient = nil
        #expect(!store.isRecoveringConnection)

        let started = ContinuousClock.now
        #expect(await store.submitComposer() == false)

        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(store.terminalSendStatus(forTerminalID: Self.terminalID) == .failed)
        #expect(store.terminalInputText == "hello")
    }

    @Test func sendDuringRecoveryFailsWhenTheWaitBoundElapses() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            reconnectAttemptDeadlineNanoseconds: 100_000_000
        )
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: Self.terminalID))
        store.terminalInputText = "hello"
        _ = try retireClientForRecovery(store)

        let started = ContinuousClock.now
        #expect(await store.submitComposer() == false)

        #expect(ContinuousClock.now - started >= .milliseconds(100))
        #expect(store.remoteClient == nil)
        #expect(store.terminalSendStatus(forTerminalID: Self.terminalID) == .failed)
        #expect(store.terminalInputText == "hello")
        #expect(await router.recordedPastes().isEmpty)
    }

    @Test func sendDuringRecoveryFailsAsSoonAsRecoveryFails() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        store.selectTerminal(MobileTerminalPreview.ID(rawValue: Self.terminalID))
        store.terminalInputText = "hello"
        let attempt = try retireClientForRecovery(store)

        let submit = Task { await store.submitComposer() }
        #expect(try await pollUntil {
            store.terminalSendStatus(forTerminalID: Self.terminalID) == .sending
        })

        #expect(store.connectionRecoveryOwner.fail(attempt))
        store.applyConnectionRecoveryOwnerState()
        #expect(store.connectionRecoveryFailed)

        #expect(await submit.value == false)
        #expect(store.terminalSendStatus(forTerminalID: Self.terminalID) == .failed)
        #expect(store.terminalInputText == "hello")
    }

    @Test func connectionClosedPasteFailureStartsDeadConnectionRecovery() async throws {
        let router = RoutingHostRouter()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pairedMacStore = try MobilePairedMacStore(
            databaseURL: directory.appendingPathComponent("paired-macs.sqlite3")
        )
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56585)
        )
        try await pairedMacStore.upsert(
            macDeviceID: "test-mac",
            displayName: "Test Mac",
            routes: [route],
            markActive: true,
            stackUserID: "routing-user",
            teamID: nil,
            now: Date()
        )
        let store = try await makeRoutingConnectedStore(
            router: router,
            pairedMacStore: pairedMacStore
        )
        defer { store.connectionRecoveryOwner.cancel() }
        let client = try #require(store.remoteClient)

        store.handleMacAvailabilityFailureIfCurrent(
            after: MobileShellConnectionError.connectionClosed,
            expectedClient: client,
            expectedGeneration: store.connectionGeneration
        )

        // The scripted host cannot complete a redial, so the attempt may already
        // have settled as failed by the time the poll observes it. What must
        // hold either way: the dead client was retired and a redial was dialed,
        // rather than the shell only flipping to "unavailable" on the live client.
        #expect(try await pollUntil {
            store.remoteClient == nil && store.storedMacReconnectGeneration >= 1
        })
        #expect(store.connectionRecoveryOwner.activeAttempt?.trigger == "requestConnectionClosed")
    }
}
