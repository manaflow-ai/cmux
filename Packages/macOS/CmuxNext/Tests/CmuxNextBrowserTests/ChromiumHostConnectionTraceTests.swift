#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Darwin
import Testing

/// Each input frame (mouse, wheel, key, edit) cmux writes to the Chromium host is one `cef.host_input` instant with
/// its wire kind (perf-hot `cef-host-input`); a frame that is not input, or not written,
/// records nothing. The test plays the host on two socket pairs and records into its own trace runtime.
@Suite(.serialized) struct ChromiumHostConnectionTraceTests {
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

    /// cmux's end reads `back[1]` and writes `pair[0]`; the test plays the host on `pair[1]` and `back[0]`.
    private final class Rig {
        let log = RecordLog()
        let runtime: TraceRuntime
        let connection: ChromiumHostConnection
        private let hostFDs: [Int32]

        init() throws {
            var pair: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            var back: [Int32] = [-1, -1]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &back) == 0)
            hostFDs = [pair[1], back[0]]
            runtime = log.runtime()
            runtime.setCategories(.all)
            connection = ChromiumHostConnection(readFD: back[1], writeFD: pair[0],
                                                signposter: Signposter(category: .cef, mirror: SignpostMetricKitMirror(),
                                                                       trace: runtime))
        }

        func close() {
            connection.close()
            hostFDs.forEach { _ = Darwin.close($0) }
        }
    }

    @Test func eachWrittenInputFrameIsOneHostInputInstantWithItsKind() throws {
        let rig = try Rig()
        defer { rig.close() }

        #expect(rig.connection.send(ChromiumHostFrame(.mouse, v: [1, 2])))
        #expect(rig.connection.send(ChromiumHostFrame(.wheel, v: [0, -3])))
        #expect(rig.connection.send(ChromiumHostFrame(.key, v: [0x24])))
        #expect(rig.connection.send(ChromiumHostFrame(.edit, v: [2])))
        let oversized = ChromiumHostFrame(.key, payload: [UInt8](repeating: 0x61, count: ChromiumHostFrame.maxPayload + 1))
        #expect(!rig.connection.send(oversized))

        let records = rig.log.hostInputs
        #expect(records.map(\.phase) == [.instant, .instant, .instant, .instant])
        #expect(records.map(\.arg0) == [ChromiumHostFrame.Kind.mouse, .wheel, .key, .edit].map { UInt64($0.rawValue) })
    }

    /// Navigation, geometry (one per resize or motion step), focus, ping, stats and quit are not input.
    @Test func aFrameThatIsNotInputRecordsNothing() throws {
        let rig = try Rig()
        defer { rig.close() }

        #expect(rig.connection.send(ChromiumHostFrame(.navigate, payload: Array("https://example.com".utf8))))
        #expect(rig.connection.send(ChromiumHostFrame(.geometry, v: [800, 600, 0, 0, 2_000])))
        #expect(rig.connection.send(ChromiumHostFrame(.focus, v: [1])))
        #expect(rig.connection.send(ChromiumHostFrame(.ping, t0: 1)))
        #expect(rig.connection.send(ChromiumHostFrame(.stats)))
        #expect(rig.connection.send(ChromiumHostFrame(.quit)))

        #expect(rig.log.hostInputs.isEmpty)
    }

    /// Cmd-V and Cmd-A reach the host as edit frames: their timing is a keystroke's, like a key frame's. The
    /// frames are still sent; only their instants are not recorded.
    @Test func theKeystrokeTimingGateDropsKeyAndEditInstantsButSendsTheFrames() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.runtime.setKeyTimingSuppressed(true, by: .terminalSecureInput)

        #expect(rig.connection.send(ChromiumHostFrame(.key, v: [0x24])))
        #expect(rig.connection.send(ChromiumHostFrame(.edit, v: [2])))
        #expect(rig.connection.send(ChromiumHostFrame(.mouse, v: [1, 2])))

        #expect(rig.log.hostInputs.map(\.arg0) == [UInt64(ChromiumHostFrame.Kind.mouse.rawValue)])
    }

    @Test func everyTracedInputKindKeepsItsWireNumber() {
        for kind in [ChromiumHostFrame.Kind.mouse, .wheel, .key, .edit] {
            #expect(kind.traceInput?.rawValue == kind.rawValue)
        }
    }
}
#endif
