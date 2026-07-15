import Foundation
import Testing
@testable import CmuxMobileRPC

@Test func eventOverflowPreservesOldestOrderAndTerminatesTheSubscription() async throws {
    let session = MobileCoreRPCSession(makeTransport: {
        Issue.record("transport should not be created by direct event dispatch")
        throw MobileShellConnectionError.connectionClosed
    })
    let subscription = await session.addEventListener(topics: ["terminal.render_grid"])

    for sequence in 1...MobileCoreRPCSession.eventListenerBufferCapacity {
        let accepted = await session.dispatchFrameForTesting(try eventFrame(sequence: sequence))
        #expect(accepted)
    }
    let overflowAccepted = await session.dispatchFrameForTesting(
        try eventFrame(sequence: MobileCoreRPCSession.eventListenerBufferCapacity + 1)
    )
    #expect(!overflowAccepted)

    var iterator = subscription.stream.makeAsyncIterator()
    var sequences: [Int] = []
    while let event = await iterator.next() {
        let data = try #require(event.payloadJSON)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        sequences.append(try #require(object["sequence"] as? Int))
    }
    #expect(sequences == Array(1...MobileCoreRPCSession.eventListenerBufferCapacity))
}

private func eventFrame(sequence: Int) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "kind": "event",
        "topic": "terminal.render_grid",
        "payload": [
            "surface_id": "terminal",
            "sequence": sequence,
        ],
    ])
}
