import Foundation
import Testing
@_spi(CmuxHostTransport) @testable import CmuxExtensionKit

@Suite
struct CMUXSidebarExtensionConnectionTests {
    @Test(arguments: DisconnectPath.allCases)
    @MainActor
    func queuedSnapshotIsFencedAfterDisconnectAndFreshConnectionDelivers(
        disconnectPath: DisconnectPath
    ) async throws {
        var deliveredSequences: [UInt64] = []
        var statuses: [CmuxSidebarConnectionStatus] = []
        let connection = CMUXSidebarExtensionConnection(
            manifest: CmuxExtensionManifest(
                id: "dev.cmux.connection-generation-test",
                displayName: "Connection Generation Test",
                readScopes: []
            ),
            onSnapshot: { deliveredSequences.append($0.sequence) },
            onStatus: { statuses.append($0) }
        )

        let staleTransport = try makeTransport(for: connection)
        staleTransport.receiver.sidebarSnapshotDidChange(
            try encodedSnapshot(sequence: 1)
        )
        disconnectPath.disconnect(staleTransport.connection)

        await waitUntil { statuses.contains(.waitingForHost) }
        #expect(deliveredSequences.isEmpty)
        #expect(statuses == [.waitingForHost])

        let freshTransport = try makeTransport(for: connection)
        freshTransport.receiver.sidebarSnapshotDidChange(
            try encodedSnapshot(sequence: 2)
        )

        await waitUntil { deliveredSequences == [2] }
        #expect(deliveredSequences == [2])
        #expect(statuses == [.waitingForHost, .connected])

        connection.invalidate()
        staleTransport.connection.invalidate()
        freshTransport.connection.invalidate()
    }

    private func makeTransport(
        for extensionConnection: CMUXSidebarExtensionConnection
    ) throws -> TestTransport {
        let listener = NSXPCListener.anonymous()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        #expect(extensionConnection.accept(connection))
        let receiver = try #require(connection.exportedObject as? any CMUXSidebarExtensionXPC)
        return TestTransport(listener: listener, connection: connection, receiver: receiver)
    }

    private func encodedSnapshot(sequence: UInt64) throws -> NSData {
        try CmuxSidebarXPCCodec.encodeSnapshot(
            CmuxSidebarSnapshot(sequence: sequence, selectedWorkspaceID: nil, workspaces: [])
        )
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
    }
}

enum DisconnectPath: CaseIterable, Sendable {
    case interruption
    case invalidation

    func disconnect(_ connection: NSXPCConnection) {
        switch self {
        case .interruption:
            connection.interruptionHandler?()
        case .invalidation:
            connection.invalidationHandler?()
        }
    }
}

private struct TestTransport {
    // Retaining the anonymous listener keeps its endpoint valid while the connection is exercised.
    let listener: NSXPCListener
    let connection: NSXPCConnection
    let receiver: any CMUXSidebarExtensionXPC
}
