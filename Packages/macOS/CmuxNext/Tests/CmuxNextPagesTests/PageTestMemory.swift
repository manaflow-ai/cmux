import CmuxNextCompat
import CmuxNextMemory

/// The memory coordinator a page host pool registers with in a test: the app's coordinator over a
/// pressure source the test drives (``send(_:)``), in the app's default Memory Saver mode (medium),
/// with release slices the test runs (``runSlices()``). Keep it for the test's length.
@MainActor
final class PageTestMemory {
    private final class HeldSlices: MemoryReleaseSlicer {
        var slices: [@MainActor () -> Void] = []
        func scheduleSlice(_ slice: @escaping @MainActor () -> Void) { slices.append(slice) }
    }

    let coordinator: MemoryCoordinator
    private let source = ManualMemoryPressureSource()
    private let pressure: MemoryPressureEvents
    private let slices = HeldSlices()

    init(mode: MemorySaverMode = .medium) {
        pressure = MemoryPressureEvents(source: source)
        coordinator = MemoryCoordinator(pressure: pressure, mode: mode, slicer: slices)
    }

    /// Delivers `level` as the kernel's pressure source would.
    func send(_ level: MemoryPressureLevel) {
        source.send(level)
    }

    /// Runs the release slices asked for so far, and the ones they ask for.
    func runSlices() {
        while !slices.slices.isEmpty { slices.slices.removeFirst()() }
    }
}
