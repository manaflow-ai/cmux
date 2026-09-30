@testable import CmuxNextApp

/// Model-based fuzzing of the composed input system
/// (plans/cmux-next/input-spec.md section 6): random interleavings of
/// keyboard, mouse, key-window, Chromium page window, palette, sheet,
/// group editor, tab and pane changes, drags, daemon deltas delivered in any
/// order or rejected, and attach events, checked against every invariant.
/// A failing run is shrunk (delta debugging) to a minimal action sequence
/// that still breaks the same invariant.
enum InputFuzzer {
    struct Config: Hashable, CustomStringConvertible {
        var windows: Int
        var reportsRemoval: Bool

        var description: String { "windows: \(windows), reportsRemoval: \(reportsRemoval)" }
    }

    struct Failure: CustomStringConvertible {
        var seed: UInt64?
        var config: Config
        var violation: InputViolation
        var actions: [FuzzAction]

        var description: String {
            """
            \(violation.invariant.rawValue) (\(violation.invariant.summary)) in \(violation.window ?? "-"): \(violation.detail)
            seed \(seed.map(String.init) ?? "-"), \(config), \(actions.count) actions:
            \(actions.map { "    .\($0)," }.joined(separator: "\n"))
            """
        }
    }

    static func generate(seed: UInt64, steps: Int) -> [FuzzAction] {
        var random = SplitMix(state: seed)
        return (0..<steps).map { _ in FuzzAction.random(&random) }
    }

    static func config(seed: UInt64) -> Config {
        Config(windows: 1 + Int(seed % 3), reportsRemoval: seed % 2 == 1)
    }

    /// Runs `actions` from a fresh world. Returns the first violation and
    /// the index of the action that caused it.
    static func run(_ actions: [FuzzAction], config: Config) -> (violation: InputViolation, index: Int)? {
        let world = InputWorld(windows: config.windows, reportsRemoval: config.reportsRemoval)
        if let first = world.violations.first { return (first, -1) }
        for (index, action) in actions.enumerated() {
            world.perform(action)
            world.checkWorld()
            if let first = world.violations.first { return (first, index) }
        }
        // Let every deferred presentation land, then check once more.
        world.frame()
        world.checkWorld()
        return world.violations.first.map { ($0, actions.count) }
    }

    /// The first failure of a generated run, shrunk.
    static func fuzz(seed: UInt64, steps: Int, config: Config? = nil) -> Failure? {
        let config = config ?? Self.config(seed: seed)
        let actions = generate(seed: seed, steps: steps)
        guard let (violation, index) = run(actions, config: config) else { return nil }
        let prefix = Array(actions.prefix(index + 1))
        let minimal = shrink(prefix, config: config, invariant: violation.invariant)
        let final = run(minimal, config: config)?.violation ?? violation
        return Failure(seed: seed, config: config, violation: final, actions: minimal)
    }

    /// Delta debugging (ddmin): removes chunks, then single actions, while
    /// the run still breaks `invariant`.
    static func shrink(_ actions: [FuzzAction], config: Config, invariant: InputInvariant) -> [FuzzAction] {
        func fails(_ candidate: [FuzzAction]) -> Bool { run(candidate, config: config)?.violation.invariant == invariant }
        var current = actions
        var granularity = 2
        while current.count >= 2 {
            let size = (current.count + granularity - 1) / granularity
            var reduced = false
            var start = 0
            while start < current.count {
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
        while index < current.count {
            var candidate = current
            candidate.remove(at: index)
            if fails(candidate) { current = candidate } else { index += 1 }
        }
        return current
    }
}
