// cmux: main-actor work for a later pass of the main run loop. Not a vendored file.
import Foundation

/// Runs main-actor work on a later pass of the main run loop in the given modes (`RunLoop.main.perform`).
///
/// Foundation's block is `@Sendable` and nonisolated; the main run loop runs it on the main thread, and
/// that proof is here once, so callers pass plain main-actor work.
enum MainRunLoopPass {
    /// Queues `work` for the next pass of the main run loop in one of `modes`.
    /// - Parameters:
    ///   - modes: The run loop modes the pass may run in (`.default` waits out menu tracking; `.common` does not).
    ///   - work: Main-actor work, run once.
    static func perform(inModes modes: [RunLoop.Mode], _ work: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: modes) {
            // main-proof: RunLoop.main runs its blocks on the main thread, the main run loop's thread.
            MainActor.assumeIsolated { work() }
        }
    }
}
