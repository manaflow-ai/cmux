import CmuxFuzzSupport
import CmuxNextInputModel

/// What broke a walk, as the shrinker compares it.
struct WalkViolation: Hashable, Sendable, Codable {
    /// The invariant id (`A1`-`A4`), or `replay:<kind>` when the walk's own journal does not
    /// replay to the phases the machine reached.
    var signature: String
    var detail: String

    init(_ violation: InputViolation) {
        signature = violation.invariant.rawValue
        detail = violation.detail
    }

    init(_ divergence: InputReplay.Divergence) {
        signature = "replay:\(divergence.kind.rawValue)"
        detail = "seq \(divergence.seq) \(divergence.event): recorded \(divergence.recorded ?? "-"), replayed \(divergence.replayed ?? "-")"
    }

    init(skippedReplayEvents count: Int) {
        signature = "replay:skipped"
        detail = "the replay could not map \(count) journaled attach events"
    }
}

/// A shrunk failing walk: the file written under `--out`.
struct WalkFailure: Sendable, Codable {
    var seed: UInt64
    var config: WalkConfig
    var violation: WalkViolation
    var actions: [String]
    /// The minimized walk's journal (`InputJournalEntry` records, as `debug.journal` returns them).
    var journal: [InputJournalEntry]
}

/// One seed's walk.
struct AttachWalk {
    struct Run {
        var journal: [InputJournalEntry]
        var violation: WalkViolation?
        /// The step that broke it: -1 the setup, `actions.count` the settle or the replay.
        var index: Int
    }

    let seed: UInt64
    let config: WalkConfig
    let fault: AttachWorld.Fault?

    init(seed: UInt64, fault: AttachWorld.Fault? = nil) {
        self.seed = seed
        self.fault = fault
        config = WalkConfig(seed: seed)
    }

    func actions(steps: Int) -> [WalkAction] {
        var rng = FuzzRNG(seed: FuzzRNG.derivedSeed(seed, stream: 0))
        return (0..<steps).map { _ in WalkAction.random(&rng) }
    }

    /// Runs `actions` from a fresh world, settles it and, for an exact walk, replays its journal
    /// with `InputReplay`, which must reach the same phases.
    func run(_ actions: [WalkAction]) -> Run {
        var world = AttachWorld(config: config, fault: fault)
        if let first = world.violations.first { return Run(journal: world.journal, violation: WalkViolation(first), index: -1) }
        for (index, action) in actions.enumerated() {
            world.perform(action)
            if let first = world.violations.first { return Run(journal: world.journal, violation: WalkViolation(first), index: index) }
        }
        world.settle()
        if let first = world.violations.first {
            return Run(journal: world.journal, violation: WalkViolation(first), index: actions.count)
        }
        guard config.exact else { return Run(journal: world.journal, violation: nil, index: actions.count) }
        let replay = InputReplay(world.journal).run()
        let violation = replay.firstDivergence.map { WalkViolation($0) }
            ?? (replay.skippedAttachEvents > 0 ? WalkViolation(skippedReplayEvents: replay.skippedAttachEvents) : nil)
        return Run(journal: world.journal, violation: violation, index: actions.count)
    }

    func walk(steps: Int, shrinkBudget: Int) -> WalkOutcome {
        let script = actions(steps: steps)
        let first = run(script)
        var digest = JournalDigest()
        digest.add(first.journal)
        var outcome = WalkOutcome(seed: seed, exact: config.exact, digest: digest.value)
        guard let violation = first.violation else { return outcome }
        let minimal = shrink(Array(script.prefix(first.index + 1)), signature: violation.signature, budget: shrinkBudget)
        let last = run(minimal)
        outcome.failure = WalkFailure(seed: seed, config: config, violation: last.violation ?? violation,
                                      actions: minimal.map { String(describing: $0) }, journal: last.journal)
        return outcome
    }

    /// Delta debugging (ddmin): removes chunks, then single steps, while the walk still breaks
    /// with `signature`, within `budget` runs.
    func shrink(_ actions: [WalkAction], signature: String, budget: Int) -> [WalkAction] {
        var remaining = budget
        func fails(_ candidate: [WalkAction]) -> Bool {
            remaining -= 1
            return run(candidate).violation?.signature == signature
        }
        var current = actions
        var granularity = 2
        while current.count >= 2, remaining > 0 {
            let size = (current.count + granularity - 1) / granularity
            var reduced = false
            var start = 0
            while start < current.count, remaining > 0 {
                var candidate = current
                candidate.removeSubrange(start..<min(start + size, current.count))
                if fails(candidate) {
                    current = candidate
                    granularity = max(granularity - 1, 2)
                    reduced = true
                    break
                }
                start += size
            }
            if !reduced {
                if granularity >= current.count { break }
                granularity = min(granularity * 2, current.count)
            }
        }
        var index = 0
        while index < current.count, remaining > 0 {
            var candidate = current
            candidate.remove(at: index)
            if fails(candidate) { current = candidate } else { index += 1 }
        }
        return current
    }
}
