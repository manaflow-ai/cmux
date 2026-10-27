@testable import CmuxNextDaemon
import Foundation
import Testing

/// The app half of the person-input lane (p01-process-235): a person's key keeps its call order on the wire, so it
/// never leaves before a control line of its own surface that still waits in the socket writer.
@Suite(.serialized, .timeLimit(.minutes(1))) struct PersonInputLaneTests {
    /// Control lines queued before the key, each `padding` long: 4 MiB, far past the socket buffers, so most
    /// of them still wait in the writer when the key is written.
    static let controlLines = 128
    static let padding = String(repeating: "x", count: 32 << 10)

    @Test func aPersonKeyLeavesAfterTheQueuedControlLinesOfItsSurface() async throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil)
        try daemon.accept()
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        var control: [UInt64] = []
        for _ in 0..<Self.controlLines {
            let id = try transport.submit(.discard(cmd: "resize", onError: nil)) { id in
                Data(#"{"id":\#(id),"cmd":"resize","surface":1,"pad":"\#(Self.padding)"}"#.utf8)
            }.get()
            control.append(id)
        }
        // The person-input path: DaemonPersonInput.send -> DaemonConnection.request -> this executor.
        let key = Task {
            try await DaemonRequestExecutor(transport: transport)
                .perform(SendKeyRequest(surface: SurfaceID(rawValue: 1), keys: ["a"]), timeout: nil)
        }
        defer { key.cancel() }
        var ids: [UInt64] = []
        for _ in 0...Self.controlLines {
            ids.append(try daemon.readRequestID())
        }
        #expect(Array(ids.prefix(Self.controlLines)) == control, "the key left before a control line of its surface")
        #expect(ids.last.map { !control.contains($0) } == true)
    }
}
