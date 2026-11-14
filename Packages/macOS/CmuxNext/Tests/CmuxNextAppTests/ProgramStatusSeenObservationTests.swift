@testable import CmuxNextBridge
import CmuxNextDaemon
import Observation
import Testing

/// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". The seen set was one observed value, so
/// a look at one tab (focus, a click, every keystroke that took a record) woke every tab and sidebar row that shows a
/// program status, and each mapped again: O(rows) per look. A reader now observes its own terminal only.
@MainActor @Suite struct ProgramStatusSeenObservationTests {
    static func done(_ id: String, seq: UInt64) -> ProgramStatusRecord {
        ProgramStatusRecord(id: id, state: .done, updatedSeq: seq)
    }

    @MainActor final class Woken { var count = 0 }

    /// Observes `terminal`'s visible records the way a row's mapping reads them; counts the changes it hears.
    private static func observe(_ store: ProgramStatusSeenStore, terminal: String, _ woken: Woken) {
        withObservationTracking {
            _ = store.visible([done("r", seq: 1)], terminal: terminal)
        } onChange: {
            Task { @MainActor in woken.count += 1 }
        }
    }

    @Test func aLookAtOneTerminalWakesNoReaderOfAnother() async {
        let store = ProgramStatusSeenStore()
        let others = (0..<100).map { _ in Woken() }
        for (index, woken) in others.enumerated() { Self.observe(store, terminal: "terminal:other-\(index)", woken) }
        let mine = Woken()
        Self.observe(store, terminal: "terminal:me", mine)

        store.markSeen([Self.done("r", seq: 1)], terminal: "terminal:me")
        for _ in 0..<5 { await Task.yield() }

        let wokenOthers = others.reduce(0) { $0 + $1.count }
        print("program-status-seen wakes of 100 other terminals' readers per look: \(wokenOthers)")
        #expect(wokenOthers == 0, "a look at one terminal woke \(wokenOthers) readers of other terminals")
        #expect(mine.count == 1, "the looked-at terminal's reader was not told")
        #expect(store.visible([Self.done("r", seq: 1)], terminal: "terminal:me").isEmpty)
        #expect(store.visible([Self.done("r", seq: 1)], terminal: "terminal:other-0").count == 1)
    }

    /// A full set pushes the oldest keys out: their terminal's reader hears it, as its record shows again.
    @Test func aKeyTheLimitPushesOutWakesItsTerminalsReader() async {
        let store = ProgramStatusSeenStore()
        store.markSeen([Self.done("r", seq: 1)], terminal: "terminal:oldest")
        for index in 0..<(ProgramStatusSeen.limit - 1) { store.markSeen([Self.done("r", seq: 1)], terminal: "terminal:t\(index)") }
        let oldest = Woken()
        Self.observe(store, terminal: "terminal:oldest", oldest)
        store.markSeen([Self.done("r", seq: 1)], terminal: "terminal:newest")
        for _ in 0..<5 { await Task.yield() }
        #expect(oldest.count == 1)
        #expect(store.visible([Self.done("r", seq: 1)], terminal: "terminal:oldest").count == 1)
    }
}
