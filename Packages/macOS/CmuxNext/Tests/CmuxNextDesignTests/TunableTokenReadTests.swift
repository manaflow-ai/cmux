import CmuxNextDesignTokens
import Observation
import os
import Testing

/// A tunable is read by its declaration's identity (`TunableToken`), not by hashing its key: the
/// read runs per sidebar row and per tab item (sweep 2026-10-23: 67 ms in one STRESS
/// palette.openCmuxSettingsFile, in `TunableStore.override`). The read must still see every
/// write, by key or by tunable, and a view that read it must hear the change.
struct TunableTokenReadTests {
    static let probe = Tunable<Double>.number("test.tokenRead.probe", .dropOverlay, "Probe", help: "test",
                                                default: 1, range: 0...10, step: 1, unit: .points)

    @Test @MainActor func aRegisteredTunableSeesWritesAndTellsObservers() {
        let store = TunableStore()
        store.register([Self.probe.descriptor])
        store.activate(file: nil)
        #expect(Self.probe.value(in: store) == 1)

        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = Self.probe.value(in: store) } onChange: { changed.withLock { $0 = true } }
        store.set(Self.probe.key, .number(4))
        #expect(changed.withLock { $0 }, "a reader by token hears a write by key")
        #expect(Self.probe.value(in: store) == 4)

        store.reset([Self.probe.key])
        #expect(Self.probe.value(in: store) == 1)
    }

    /// A descriptor the store never registered (a copy made elsewhere with the same key) reads by
    /// key, as before.
    @Test @MainActor func anUnregisteredDeclarationReadsByKey() {
        let store = TunableStore()
        store.register([Self.probe.descriptor])
        store.activate(file: nil)
        store.set(Self.probe.key, .number(7))
        let other = Tunable<Double>.number("test.tokenRead.probe", .dropOverlay, "Probe", help: "test",
                                           default: 1, range: 0...10, step: 1, unit: .points)
        #expect(other.value(in: store) == 7)
    }
}
