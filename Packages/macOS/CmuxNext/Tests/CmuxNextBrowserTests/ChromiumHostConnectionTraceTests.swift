#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Darwin
import Testing

/// Each frame cmux writes to the Chromium host is one `cef.host_input` instant with its wire kind
/// (p09-observability-038, perf-hot `cef-host-input`); a frame that is not written records nothing. The test plays
/// the host on two socket pairs and records into its own trace runtime.
@Suite struct ChromiumHostConnectionTraceTests {
    private nonisolated final class RecordLog: Sendable {
        private let state = Mutex<[TraceRuntime.StubRecord]>([])

        var hostInputs: [TraceRuntime.StubRecord] {
            state.withLock { $0.filter { $0.name == SignpostName.cefHostInput.rawValue } }
        }

        func runtime() -> TraceRuntime {
            TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { [self] record in
                state.withLock { $0.append(record) }
            })
        }
    }

    @Test func eachWrittenFrameIsOneHostInputInstantWithItsKind() {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        var back: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &back) == 0)
        defer { [pair[1], back[0]].forEach { _ = Darwin.close($0) } }
        let log = RecordLog()
        let runtime = log.runtime()
        runtime.setCategories([.cef])
        // cmux's end reads back[1] and writes pair[0]; the test plays the host on pair[1] and back[0].
        let connection = ChromiumHostConnection(readFD: back[1], writeFD: pair[0],
                                                signposter: Signposter(category: .cef, mirror: SignpostMetricKitMirror(),
                                                                       trace: runtime))
        defer { connection.close() }

        #expect(connection.send(ChromiumHostFrame(.mouse, v: [1, 2])))
        #expect(connection.send(ChromiumHostFrame(.key, v: [0x24])))
        let oversized = ChromiumHostFrame(.navigate, payload: [UInt8](repeating: 0x61, count: ChromiumHostFrame.maxPayload + 1))
        #expect(!connection.send(oversized))

        let records = log.hostInputs
        #expect(records.map(\.phase) == [.instant, .instant])
        #expect(records.map(\.arg0) == [UInt64(ChromiumHostFrame.Kind.mouse.rawValue), UInt64(ChromiumHostFrame.Kind.key.rawValue)])
    }
}
#endif
