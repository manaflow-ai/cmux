import CMUXMobileCore
import Foundation

actor SessionPurposeRecordingTransport:
    CmxByteTransport,
    CmxByteTransportSessionPurposeUpdating
{
    private let base: ControllableResponseTransport
    private var purposes: [CmxTransportSessionPurpose] = []

    init(automaticallyRespondingRequestIDs: Set<String>) {
        base = ControllableResponseTransport(
            closeEndsReceive: true,
            automaticallyRespondingRequestIDs:
                automaticallyRespondingRequestIDs
        )
    }

    func updateSessionPurpose(_ purpose: CmxTransportSessionPurpose) {
        purposes.append(purpose)
    }

    func connect() async throws {
        try await base.connect()
    }

    func receive() async throws -> Data? {
        try await base.receive()
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func close() async {
        await base.close()
    }

    func recordedPurposes() -> [CmxTransportSessionPurpose] {
        purposes
    }
}
