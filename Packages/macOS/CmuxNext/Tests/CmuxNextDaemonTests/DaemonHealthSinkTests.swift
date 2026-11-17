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

    /// 2026-11-13, after a self-update: the ensure's progress watch sees stdout writes on its own
    /// queue, so the last one (the ensure's JSON result) can arrive after the ensure returned and
    /// noted ready. App health then read a restore with no progress and, two minutes later, showed
    /// "Session service isn't responding" for an owner that answered. A write after the end is no
    /// progress.
    @Test func aProgressWriteAfterTheEnsureEndedIsNoRestore() {
        let sink = DaemonHealthSink()
        let seen = Mutex<[DaemonHealthSink.Signal]>([])
        sink.bind { signal in seen.withLock { $0.append(signal) } }
        let note = EnsureProgressNote(sink)
        note.progressed()
        note.end(.ready(pid: 7))
        note.progressed() // the result's write, seen late on the watch's queue
        #expect(seen.withLock { $0 } == [.started, .restoring, .ready(pid: 7)])

        // An ensure whose only write is its result, seen after the end: nothing but the outcome.
        let late = EnsureProgressNote(sink)
        seen.withLock { $0 = [] }
        late.end(.ready(pid: 8))
        late.progressed()
        #expect(seen.withLock { $0 } == [.ready(pid: 8)])
    }
}
