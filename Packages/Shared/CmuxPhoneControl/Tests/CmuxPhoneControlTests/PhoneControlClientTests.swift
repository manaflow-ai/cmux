#if canImport(Network)
import Network
import Testing

@testable import CmuxPhoneControl

@Suite("cmux.phone typed client")
struct PhoneControlClientTests {
    @Test
    func typedClientCompletesAFullLoopbackFlow() async throws {
        let server = try PhoneTCPServer(port: 0, driver: MockPhoneDriver())
        let port = try await server.start()
        defer { server.stop() }
        let client = try PhoneControlClient(port: port)

        let devices = try await client.listDevices()
        #expect(devices.count == 1)
        #expect(devices.first?.source == .mock)

        let session = try await client.openSession()
        #expect(await client.sessionID == session.sessionID)

        let frame = try await client.snapshot()
        let receipt = try await client.perform(.init(
            actionID: "typed-client-tap",
            kind: .tap,
            screenSequence: frame.sequence,
            point: .init(x: 0.5, y: 0.5)
        ))
        #expect(receipt.accepted)
        #expect(receipt.screenSequence == frame.sequence + 1)
        #expect(try await client.nextEvent().method == "ui.changed")

        let tree = try await client.accessibilityTree()
        #expect(tree?.role == "window")

        try await client.closeSession()
        await client.close()
    }

    @Test
    func clientRefusesNonLoopbackEndpoints() throws {
        #expect(throws: PhoneControlClientError.invalidEndpoint) {
            _ = try PhoneControlClient(host: "192.0.2.10", port: 8100)
        }
        #expect(throws: PhoneControlClientError.invalidEndpoint) {
            _ = try PhoneControlClient(host: "127.0.0.1", port: 0)
        }
    }
}

#endif
