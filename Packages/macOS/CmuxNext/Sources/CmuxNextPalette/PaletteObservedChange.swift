import Foundation

/// One Observation-tracked pass of the palette view (a whole render, or the hover), and whether a
/// model change since then waits for the next pass.
///
/// ``isPending`` turns true in the change's will-set, before the hop that runs the next pass, so a
/// test reads at once which pass a model change scheduled. The palette's model is main-actor
/// state, so its writes, and so the will-set, run on the main thread.
@MainActor
final class PaletteObservedChange {
    /// A model change since the last ``track(_:then:)`` waits for its pass.
    private(set) var isPending = false

    /// Runs `pass` under observation tracking; the first change of what it read sets
    /// ``isPending`` and runs `next` in a main-actor task.
    func track(_ pass: () -> Void, then next: @escaping @MainActor @Sendable () -> Void) {
        isPending = false
        withObservationTracking(pass) { [weak self] in
            // main-proof: checked on this line; the model's writes run on the main actor
            if Thread.isMainThread { MainActor.assumeIsolated { self?.isPending = true } }
            Task { @MainActor in next() }
        }
    }
}
