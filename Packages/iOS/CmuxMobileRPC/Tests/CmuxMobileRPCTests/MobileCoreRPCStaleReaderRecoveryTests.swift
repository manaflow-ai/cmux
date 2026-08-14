import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileCoreRPCStaleReaderRecoveryTests {
    @Test func sequencedFactoryRejectsUnexpectedExtraTransportCreation() throws {
        let factory = SequencedTransportFactory([
            ControllableResponseTransport(closeEndsReceive: true),
        ])
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 59136
        )

        _ = try factory.makeTransport(for: route)
        #expect(throws: SequencedTransportFactoryError.exhausted) {
            _ = try factory.makeTransport(for: route)
        }
        #expect(factory.createdTransportCount() == 1)
    }

    @Test func staleReaderCannotAnswerReplacementSessionRequest() async throws {
        let stale = ControllableResponseTransport(closeEndsReceive: false)
        let replacement = ControllableResponseTransport(closeEndsReceive: true)
        let factory = SequencedTransportFactory([stale, replacement])
        let client = try makeClient(factory: factory)

        let oldTask = Task {
            try await client.sendRequest(
                try inputRequest(id: "old-pending"),
                timeoutNanoseconds: 60 * 1_000_000_000
            )
        }
        await stale.waitUntilSent(count: 1)
        await client.session.tearDown(error: .connectionClosed)
        _ = try? await oldTask.value

        let completion = AsyncFlag()
        let reusedID = "reused-after-reset"
        let replacementTask = Task {
            let data = try await client.sendRequest(
                try inputRequest(id: reusedID),
                timeoutNanoseconds: 60 * 1_000_000_000
            )
            await completion.set()
            return data
        }
        await replacement.waitUntilSent(count: 1)

        try await stale.deliverResponse(id: reusedID, status: "stale")
        for _ in 0..<100 where !(await completion.isSet()) {
            await Task.yield()
        }
        #expect(!(await completion.isSet()))

        try await replacement.deliverResponse(id: reusedID, status: "fresh")
        let data = try await replacementTask.value
        let response = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        #expect(response["status"] == "fresh")

        await stale.finishReceiving()
        await client.disconnect()
    }

    private func makeClient(
        factory: any CmxByteTransportFactory
    ) throws -> MobileCoreRPCClient {
        let route = try hostPortRoute(
            kind: .debugLoopback,
            host: "127.0.0.1",
            port: 59136
        )
        let runtime = TestMobileSyncRuntime(transportFactory: factory)
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-main",
            terminalID: "terminal-main",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [route],
            expiresAt: Date().addingTimeInterval(60),
            authToken: "ticket-secret"
        )
        return MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
    }

    private func inputRequest(id: String) throws -> Data {
        try MobileCoreRPCClient.requestData(
            method: "terminal.input",
            params: [
                "workspace_id": "workspace-main",
                "terminal_id": "terminal-main",
                "text": "x",
            ],
            id: id
        )
    }
}
