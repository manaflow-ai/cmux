#if DEBUG
@testable import CmuxNextCompat
import CmuxNextRemoteView
import Foundation
import Testing

/// A remote browser tab's key and pointer events go to the rd transport from the main actor
/// (`RemoteBrowserTab.handleKey`, `RemoteBrowserSession.sendPointer`). They are queued and never
/// wait for the transport queue on the main thread (plans/cmux-next/threading-model.md: a
/// `dispatch_sync` from the main thread is reported). Each test binds its own blocking table.
@MainActor @Suite(.serialized)
struct RemoteRdServiceInputTests {
    /// A byte path that never opens: the session stays before its welcome.
    private nonisolated final class SilentCarrier: RemoteRdByteCarrier {
        func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {}
        func send(_ bytes: Data) {}
        func cancel() {}
    }

    private static func transport() throws -> RemoteRdStreamTransport {
        try #require(RemoteRdStreamTransport.remoteBrowser(carrier: SilentCarrier(), user: "viewer", install: "test"))
    }

    @Test func serviceInputFromTheMainThreadNeverWaitsForTheTransportQueue() async throws {
        let transport = try Self.transport()
        transport.connect()
        let table = BlockingViolationTable(mode: .record)

        await BlockingViolationTable.$scoped.withValue(table) {
            _ = transport.sendServiceInput(Data("{\"t\":\"key\"}".utf8), mustDeliver: true)
        }
        await table.flush()

        #expect(table.sites.isEmpty, "service input waited for the transport queue on the main thread: \(table.sites)")
    }
}
#endif
