import Foundation
import Testing
@testable import CmuxMobileRPC

@Test func renderEventOverflowTerminatesOnlyTheAffectedSubscription() async throws {
    let session = MobileCoreRPCSession(makeTransport: {
        Issue.record("transport should not be created by direct event dispatch")
        throw MobileShellConnectionError.connectionClosed
    })
    let renderSubscription = await session.addEventListener(topics: ["terminal.render_grid"])
    let workspaceSubscription = await session.addEventListener(topics: ["workspace.updated"])

    for sequence in 1...MobileCoreRPCSession.maximumRetainedRenderGridEventCount {
        let accepted = await session.dispatchFrameForTesting(try eventFrame(sequence: sequence))
        #expect(accepted)
    }
    let overflowAccepted = await session.dispatchFrameForTesting(
        try eventFrame(sequence: MobileCoreRPCSession.maximumRetainedRenderGridEventCount + 1)
    )
    #expect(overflowAccepted)
    #expect(await session.dispatchFrameForTesting(try workspaceEventFrame(sequence: 1)))

    var iterator = renderSubscription.stream.makeAsyncIterator()
    var sequences: [Int] = []
    while let event = await iterator.next() {
        let data = try #require(event.payloadJSON)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        sequences.append(try #require(object["sequence"] as? Int))
    }
    #expect(sequences == Array(1...MobileCoreRPCSession.maximumRetainedRenderGridEventCount))
    #expect(renderSubscription.stream.terminationReason == .bufferOverflow)

    var workspaceIterator = workspaceSubscription.stream.makeAsyncIterator()
    let workspaceEvent = try #require(await workspaceIterator.next())
    #expect(workspaceEvent.topic == "workspace.updated")
    #expect(workspaceSubscription.stream.terminationReason == nil)
}

@Test func smallEventBurstStaysWithinTheByteBudget() async throws {
    let session = MobileCoreRPCSession(makeTransport: {
        Issue.record("transport should not be created by direct event dispatch")
        throw MobileShellConnectionError.connectionClosed
    })
    let subscription = await session.addEventListener(topics: ["workspace.updated"])
    let eventCount = 32

    for sequence in 1...eventCount {
        #expect(await session.dispatchFrameForTesting(try workspaceEventFrame(sequence: sequence)))
    }

    var iterator = subscription.stream.makeAsyncIterator()
    var sequences: [Int] = []
    for _ in 0..<eventCount {
        let event = try #require(await iterator.next())
        let data = try #require(event.payloadJSON)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        sequences.append(try #require(object["sequence"] as? Int))
    }
    #expect(sequences == Array(1...eventCount))
    #expect(subscription.stream.terminationReason == nil)
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

private func workspaceEventFrame(sequence: Int) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "kind": "event",
        "topic": "workspace.updated",
        "payload": ["sequence": sequence],
    ])
}
