import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

struct MobileCoreRPCNativeWriteLifetimeTests {
    @Test(arguments: [false, true])
    func requestDeadlineOrCancellationPreservesNativeWrite(cancel: Bool) async throws {
        let base = ControllableResponseTransport(
            closeEndsReceive: true,
            blocksFirstSend: true,
            automaticallyRespondingRequestIDs: ["after-drain"]
        )
        let transport = NativeObservedResponseTransport(base: base)
        let session = MobileCoreRPCSession(
            cancelledWriteCompletionGraceNanoseconds: 1_000_000,
            makeTransport: { transport }
        )
        let first = Task {
            try await session.send(
                payload: try Self.request("blocked"),
                requestID: "blocked",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 50_000_000
            )
        }
        await base.waitUntilSent(count: 1)
        if cancel { first.cancel() }
        do {
            _ = try await first.value
            Issue.record("Expected the request to settle before the write drains")
        } catch is CancellationError {
            #expect(cancel)
        } catch MobileShellConnectionError.requestTimedOut {
            #expect(!cancel)
        } catch {
            Issue.record("A request deadline must not become a connection failure: \(error)")
        }

        // Demand behind the blocked frame also expires locally. It must neither
        // interrupt the frame nor recycle the connection after the 1ms grace.
        do {
            _ = try await session.send(
                payload: try Self.request("queued"),
                requestID: "queued",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000
            )
            Issue.record("Expected the queued request to expire")
        } catch MobileShellConnectionError.requestTimedOut {
        } catch {
            Issue.record("Expected an operation timeout, got \(error)")
        }
        #expect(await !base.closed())
        #expect(await base.sentIDs() == ["blocked"])
        await base.releaseFirstSend()

        _ = try await session.send(
            payload: try Self.request("after-drain"),
            requestID: "after-drain",
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        )
        #expect(await base.sentIDs() == ["blocked", "after-drain"])
        #expect(await !base.closed())
        await session.tearDown(error: .connectionClosed)
    }

    @Test func replyAfterLargeEventBatchArrivesWithoutAnotherNetworkRead() async throws {
        let base = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { base })
        let request = Task {
            try await session.send(
                payload: try Self.request("after-burst"),
                requestID: "after-burst",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            )
        }
        await base.waitUntilSent(count: 1)
        try await base.deliverCoalescedResponse(id: "after-burst", eventCount: 600)
        _ = try await request.value
        #expect(await !base.closed())
        await session.tearDown(error: .connectionClosed)
    }

    @Test func coalescedFrameTailRespectsPerFrameLimit() async throws {
        let base = ControllableResponseTransport(closeEndsReceive: true)
        let session = MobileCoreRPCSession(makeTransport: { base })
        let request = Task {
            try await session.send(
                payload: try Self.request("after-large-frame"),
                requestID: "after-large-frame",
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            )
        }
        await base.waitUntilSent(count: 1)
        var payload = Data(#"{"kind":"event","topic":"workspace.updated","payload":{}}"#.utf8)
        payload.append(Data(repeating: 0x20, count: MobileSyncFrameCodec.defaultMaximumFrameByteCount - payload.count))
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        await base.deliverRawChunk(Data(frame.dropLast()))
        var tail = Data(frame.suffix(1))
        tail.append(try MobileSyncFrameCodec.encodeFrame(
            Data(#"{"id":"after-large-frame","ok":true,"result":{}}"#.utf8)
        ))
        await base.deliverRawChunk(tail)
        _ = try await request.value
        #expect(await !base.closed())
        await session.tearDown(error: .connectionClosed)
    }

    private static func request(_ id: String) throws -> Data {
        try MobileCoreRPCClient.requestData(method: "terminal.input", params: ["text": id], id: id)
    }
}
