import CmuxNextCompat
@testable import CmuxNextDaemon
import Testing

/// App health's daemon sink keeps its signals in order across the bind: one noted while the
/// buffered ones are delivered arrives after them, never before.
@Suite struct DaemonHealthSinkTests {
    @Test func aSignalNotedWhileTheBindDeliversArrivesAfterTheBufferedOnes() {
        let sink = DaemonHealthSink()
        sink.note(.started)
        sink.note(.restoring)
        let seen = Mutex<[DaemonHealthSink.Signal]>([])
        sink.bind { signal in
            seen.withLock { $0.append(signal) }
            // The owner answers while the bind still delivers the buffered start.
            if signal == .started { sink.note(.ready(pid: 7)) }
        }
        sink.note(.exited)
        #expect(seen.withLock { $0 } == [.started, .restoring, .ready(pid: 7), .exited])
    }
}
