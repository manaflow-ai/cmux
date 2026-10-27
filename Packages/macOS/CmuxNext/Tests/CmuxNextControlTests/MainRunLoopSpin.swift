import Foundation

/// Runs `passes` short passes of the main run loop, where a scheduler's turns
/// (`MainWorkScheduler.post`, `postFromAnyThread`) and the observation hops arrive. A sync test
/// body is one main-queue job, and `await Task.yield()` does not run the run loop's blocks.
@MainActor
func spinMainRunLoop(passes: Int) {
    for _ in 0..<passes { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001)) }
}

/// Main run loop passes until `done` or 5 s.
@MainActor
func spinMainRunLoop(until done: () -> Bool) {
    let end = Date(timeIntervalSinceNow: 5)
    while !done(), Date() < end { spinMainRunLoop(passes: 1) }
}
