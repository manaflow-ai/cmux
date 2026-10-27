import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// p10-stability-167: the session's frame dispatch writes an event's payload and a response's result back as
/// JSON bytes. A host that sends a bare string, number or null there made
/// `JSONSerialization.data(withJSONObject:)` raise "Invalid top-level type in JSON write" (the app ended);
/// through CheckedJSON the response settles as `.invalidResponse` and the event arrives with no payload data.
struct MobileCoreRPCSessionNonObjectFrameTests {
    @Test(arguments: [#""text""#, "null", "3"])
    func anOkResponseWithANonObjectResultSettlesAsInvalidResponse(result: String) async throws {
        let base = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { base })
        let request = Task {
            try await session.send(
                payload: try Self.request("non-object-result"),
                requestID: "non-object-result",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            )
        }
        await base.waitUntilSent(count: 1)
        await base.deliverRawChunk(try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"non-object-result","ok":true,"result":\#(result)}"#.utf8)
        ))
        do {
            _ = try await request.value
            Issue.record("a \(result) result must not settle as a success")
        } catch MobileShellConnectionError.invalidResponse {
        } catch {
            Issue.record("expected invalidResponse, got \(error)")
        }
        #expect(await !base.closed())
        await session.tearDown(error: .connectionClosed)
    }

    @Test(arguments: [#""text""#, "null", "7"])
    func anEventWithANonObjectPayloadArrivesWithoutPayloadData(payload: String) async throws {
        let base = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { base })
        var events = await session.addEventListener(topics: ["workspace.updated"]).stream.makeAsyncIterator()
        let request = Task {
            try await session.send(
                payload: try Self.request("open"),
                requestID: "open",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            )
        }
        await base.waitUntilSent(count: 1)
        var chunk = try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"kind":"event","topic":"workspace.updated","stream_id":"s1","payload":\#(payload)}"#.utf8)
        )
        chunk.append(try MobileSyncFrameCodec.encodeFrame(Data(#"{"id":"open","ok":true,"result":{}}"#.utf8)))
        await base.deliverRawChunk(chunk)

        let event = try #require(await events.next())
        #expect(event.topic == "workspace.updated")
        #expect(event.streamID == "s1")
        #expect(event.payloadJSON == nil)
        _ = try await request.value
        await session.tearDown(error: .connectionClosed)
    }

    private static func request(_ id: String) throws -> Data {
        try MobileCoreRPCClient.requestData(method: "terminal.input", params: ["text": id], id: id)
    }
}
