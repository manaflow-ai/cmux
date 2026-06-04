import Foundation
import Testing
@testable import CmuxGit

/// Records how many bodies run between ``enter()`` and ``leave()`` at once so a
/// test can assert the limiter never exceeds its ceiling.
private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var completed = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
        completed += 1
    }
}

@Suite struct GitProbeConcurrencyLimiterTests {
    /// 60 tasks through a ceiling of 3 must never run more than 3 bodies at
    /// once, and every task must still complete.
    @Test func capsConcurrencyAndCompletesEveryTask() async {
        let limiter = GitProbeConcurrencyLimiter(maxConcurrent: 3)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<60 {
                group.addTask {
                    await limiter.run {
                        await tracker.enter()
                        await Task.yield()
                        await Task.yield()
                        await tracker.leave()
                    }
                }
            }
        }
        #expect(await tracker.peak <= 3)
        #expect(await tracker.peak >= 1)
        #expect(await tracker.completed == 60)
    }

    /// A ceiling of 1 strictly serializes: despite yields, no two bodies are
    /// ever in flight together.
    @Test func ceilingOfOneSerializes() async {
        let limiter = GitProbeConcurrencyLimiter(maxConcurrent: 1)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<25 {
                group.addTask {
                    await limiter.run {
                        await tracker.enter()
                        await Task.yield()
                        await tracker.leave()
                    }
                }
            }
        }
        #expect(await tracker.peak == 1)
        #expect(await tracker.completed == 25)
    }

    /// A non-positive ceiling is clamped to 1 rather than deadlocking on zero
    /// available slots.
    @Test func clampsNonPositiveCeilingToOne() async {
        let limiter = GitProbeConcurrencyLimiter(maxConcurrent: 0)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await limiter.run {
                        await tracker.enter()
                        await Task.yield()
                        await tracker.leave()
                    }
                }
            }
        }
        #expect(await tracker.peak == 1)
        #expect(await tracker.completed == 10)
    }
}
