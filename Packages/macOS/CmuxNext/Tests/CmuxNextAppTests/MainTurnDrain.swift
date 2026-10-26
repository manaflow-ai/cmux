import CmuxNextCompat
import Foundation

/// Runs the main-thread work queued so far, in a fixed number of rounds, with no wait for time: each round runs the
/// queued main-actor jobs (`Task` hops) and then the main run loop until a marker block queued after the queued
/// blocks ran (the posts of a scheduler with no display link, `.sameTurn` applies). A block queued during a round runs
/// in the next one.
@MainActor
func drainMainTurns(rounds: Int = 3) async {
    for _ in 0..<rounds {
        for _ in 0..<8 { await Task.yield() }
        let marker = MainTurnMarker()
        MainRunLoopBlock.perform { marker.ran = true }
        // A non-blocking pass each: blocks queued before the marker run before it (FIFO).
        runMainRunLoop(until: marker)
    }
}

/// Non-blocking main run loop passes until `marker` ran or 64 passes ran. Synchronous, because `RunLoop.run` is
/// unavailable from async contexts.
@MainActor
private func runMainRunLoop(until marker: MainTurnMarker) {
    for _ in 0..<64 where !marker.ran { _ = RunLoop.main.run(mode: .default, before: .distantPast) }
}

@MainActor
private final class MainTurnMarker {
    var ran = false
}
