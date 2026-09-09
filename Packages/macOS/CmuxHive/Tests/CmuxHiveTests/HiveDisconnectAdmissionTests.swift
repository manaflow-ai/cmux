import CmuxMobileRPC
import Testing
@testable import CmuxHive

@MainActor
struct HiveDisconnectAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func disconnectRevokesTerminalCreationBeforeAwaitingCancelledWork() async throws {
        let gate = HiveSessionTeardownGate()
        let fixture = try HiveSessionRaceFixture(retryDelay: { _ in await gate.wait() })
        try await fixture.connect()
        let retiringClient = try #require(fixture.session.client)
        await fixture.transport.killConnection()
        var started = gate.started.stream.makeAsyncIterator()
        _ = try #require(await started.next())

        let disconnect = Task { await fixture.session.disconnect() }
        var cancelled = gate.cancelled.stream.makeAsyncIterator()
        _ = try #require(await cancelled.next())
        #expect(fixture.session.client == nil)
        #expect(fixture.session.renderGridRouter == nil)
        #expect(fixture.session.makeTerminalSession(
            workspaceID: "ws-1", terminalID: "term-1", retryDelay: { _ in }
        ) == nil)
        #expect(!fixture.session.reconnectIfNeeded())
        let connectionsBeforeRetiredRequest = await fixture.transport.connectCount
        let request = try MobileCoreRPCClient.requestData(method: "mobile.workspace.list")
        // Retirement forbids another dial, not completion on an installed
        // transport before its asynchronous teardown has run.
        do { _ = try await retiringClient.sendRequest(request) }
        catch MobileShellConnectionError.connectionClosed { }
        #expect(await fixture.transport.connectCount == connectionsBeforeRetiredRequest)

        await gate.release()
        await disconnect.value
        #expect(fixture.session.phase == .idle)
        #expect(fixture.session.reconnectIfNeeded())
        try await waitUntil { fixture.session.phase == .connected }
        #expect(fixture.session.makeTerminalSession(
            workspaceID: "ws-1", terminalID: "term-1", retryDelay: { _ in }
        ) != nil)
        await fixture.session.disconnect()
    }
}
