import Foundation

/// One seeded property-test run: `iterations` iterations by default; in long mode
/// (`CMUX_FUZZ_SECONDS`, `CMUX_FUZZ_DEADLINE`) it goes on until its time is up;
/// `CMUX_FUZZ_ITERATIONS` sets the count exactly, for a replay.
///
/// Iteration `i` draws from its own generator, seeded with
/// `FuzzRNG.derivedSeed(seed, stream: i)`, in default and long mode alike, so the
/// run's seed and the iteration name every input. A failure prints the variables
/// that replay it (`FuzzFailure.replay`): the seed and an iteration count that ends
/// with the failing iteration, which also replays a body that keeps state across
/// iterations. The body throws to fail (`FuzzRun.check`, or the decoder's own error
/// where a value is required); the run stops at the first failure, keeps the input
/// under `CMUX_FUZZ_ARTIFACTS` and throws `FuzzError.failed`.
public struct FuzzRun: Sendable {
    public let name: String
    /// The suite's seed, or `CMUX_FUZZ_SEED` when it is set.
    public let seed: UInt64
    /// The suite's iteration count, or `CMUX_FUZZ_ITERATIONS` when it is set.
    public let iterations: Int
    public let environment: FuzzEnvironment

    public init(_ name: String, seed: UInt64, iterations: Int, environment: FuzzEnvironment) {
        self.name = name
        self.seed = environment.seed ?? seed
        self.iterations = max(environment.iterations ?? iterations, 0)
        self.environment = environment
    }

    /// A run configured from the test process's `CMUX_FUZZ_*` variables.
    public init(_ name: String, seed: UInt64, iterations: Int) throws(FuzzError) {
        let environment = try FuzzEnvironment.current()
        self.init(name, seed: seed, iterations: iterations, environment: environment)
    }

    /// `seeds` plus this run's stored inputs (`CMUX_FUZZ_CORPUS/<name>/`).
    public func corpus(seeds: [Data]) throws(FuzzError) -> FuzzCorpus {
        try FuzzCorpus(name: name, seeds: seeds, environment: environment)
    }

    /// Calls `body` once per iteration with that iteration's generator; returns the iteration count.
    @discardableResult
    public func forEach(_ body: (inout FuzzRNG) throws -> Void) throws(FuzzError) -> Int {
        let artifacts = try openArtifacts()
        defer { artifacts?.finish() }
        let deadline = self.deadline()
        var iteration = 0
        while continues(after: iteration, deadline: deadline) {
            var rng = generator(for: iteration)
            try note(iteration: iteration, input: nil, artifacts: artifacts)
            try attempt(iteration: iteration, input: nil, artifacts: artifacts) { try body(&rng) }
            iteration += 1
        }
        return iteration
    }

    /// Runs `body` on each corpus input as it is (iterations -1, -2, ...), then on one mutated input per
    /// iteration: a corpus input, or random bytes one time in eight and whenever the corpus is empty,
    /// after a mutation pass that may cross it with another corpus input. Returns the number of inputs run.
    @discardableResult
    public func forEachInput(
        _ corpus: FuzzCorpus, mutator: FuzzMutator = FuzzMutator(), _ body: (Data) throws -> Void
    ) throws(FuzzError) -> Int {
        let artifacts = try openArtifacts()
        defer { artifacts?.finish() }
        let inputs = corpus.inputs
        for (index, input) in inputs.enumerated() {
            try note(iteration: -1 - index, input: input, artifacts: artifacts)
            try attempt(iteration: -1 - index, input: input, artifacts: artifacts) { try body(input) }
        }
        let deadline = self.deadline()
        var iteration = 0
        while continues(after: iteration, deadline: deadline) {
            let input = mutatedInput(iteration: iteration, inputs: inputs, mutator: mutator)
            try note(iteration: iteration, input: input, artifacts: artifacts)
            try attempt(iteration: iteration, input: input, artifacts: artifacts) { try body(input) }
            iteration += 1
        }
        return inputs.count + iteration
    }

    /// The generator of iteration `iteration`.
    public func generator(for iteration: Int) -> FuzzRNG {
        FuzzRNG(seed: FuzzRNG.derivedSeed(seed, stream: UInt64(truncatingIfNeeded: iteration)))
    }

    // MARK: - Driving

    private func deadline() -> ContinuousClock.Instant? {
        guard let budget = environment.longModeBudget(from: Date()) else { return nil }
        return ContinuousClock.now.advanced(by: .seconds(min(budget, 1e9)))
    }

    private func continues(after iteration: Int, deadline: ContinuousClock.Instant?) -> Bool {
        if iteration < iterations { return true }
        guard let deadline else { return false }
        return ContinuousClock.now < deadline
    }

    private func openArtifacts() throws(FuzzError) -> FuzzArtifacts? {
        guard let directory = environment.artifacts else { return nil }
        return try FuzzArtifacts(directory: directory, name: name)
    }

    private func note(iteration: Int, input: Data?, artifacts: FuzzArtifacts?) throws(FuzzError) {
        guard let artifacts else { return }
        let replay = FuzzFailure.replayLine(name: name, seed: seed, iteration: iteration, corpus: environment.corpus)
        try artifacts.noteInflight(seed: seed, iteration: iteration, replay: replay, input: input)
    }

    private func attempt(
        iteration: Int, input: Data?, artifacts: FuzzArtifacts?, _ body: () throws -> Void
    ) throws(FuzzError) {
        do {
            try body()
        } catch {
            throw try failed(error, iteration: iteration, input: input, artifacts: artifacts)
        }
    }

    /// The run's failure for `error` at `iteration`, its input kept under `CMUX_FUZZ_ARTIFACTS`.
    private func failed(_ error: any Error, iteration: Int, input: Data?, artifacts: FuzzArtifacts?) throws(FuzzError) -> FuzzError {
        var failure = FuzzFailure(
            name: name, seed: seed, iteration: iteration, input: input,
            reason: String(describing: error), artifact: nil, corpus: environment.corpus
        )
        failure.artifact = try artifacts?.keep(failure)
        return FuzzError.failed(failure)
    }

    /// Iteration `iteration`'s input of an input run: a corpus input, or random bytes one time in eight and
    /// whenever the corpus is empty, after a mutation pass that may cross it with another corpus input.
    private func mutatedInput(iteration: Int, inputs: [Data], mutator: FuzzMutator) -> Data {
        var rng = generator(for: iteration)
        let base = inputs.isEmpty || rng.oneIn(8) ? rng.bytes(256) : inputs[rng.below(inputs.count)]
        let partner = inputs.isEmpty ? nil : inputs[rng.below(inputs.count)]
        return mutator.mutate(base, crossingWith: partner, using: &rng)
    }

    // MARK: - Awaiting bodies

    /// ``forEach(_:)`` for a body that awaits (a socket loop, an actor, URLSession): the same iterations,
    /// generators, artifacts and replay lines, each iteration awaited to its end before the next, on the
    /// caller's isolation. The test's time limit cancels the awaiting task, so a case that hangs ends with it.
    @discardableResult
    public func forEachAwaiting(
        isolation: isolated (any Actor)? = #isolation, _ body: (inout FuzzRNG) async throws -> Void
    ) async throws(FuzzError) -> Int {
        let artifacts = try openArtifacts()
        defer { artifacts?.finish() }
        let deadline = self.deadline()
        var iteration = 0
        while continues(after: iteration, deadline: deadline) {
            var rng = generator(for: iteration)
            try note(iteration: iteration, input: nil, artifacts: artifacts)
            do {
                try await body(&rng)
            } catch {
                throw try failed(error, iteration: iteration, input: nil, artifacts: artifacts)
            }
            iteration += 1
        }
        return iteration
    }

    /// ``forEachInput(_:mutator:_:)`` for a body that awaits: the same inputs in the same order, each
    /// awaited to its end before the next, on the caller's isolation.
    @discardableResult
    public func forEachInputAwaiting(
        _ corpus: FuzzCorpus, mutator: FuzzMutator = FuzzMutator(), isolation: isolated (any Actor)? = #isolation,
        _ body: (Data) async throws -> Void
    ) async throws(FuzzError) -> Int {
        let artifacts = try openArtifacts()
        defer { artifacts?.finish() }
        let inputs = corpus.inputs
        for (index, input) in inputs.enumerated() {
            try note(iteration: -1 - index, input: input, artifacts: artifacts)
            do {
                try await body(input)
            } catch {
                throw try failed(error, iteration: -1 - index, input: input, artifacts: artifacts)
            }
        }
        let deadline = self.deadline()
        var iteration = 0
        while continues(after: iteration, deadline: deadline) {
            let input = mutatedInput(iteration: iteration, inputs: inputs, mutator: mutator)
            try note(iteration: iteration, input: input, artifacts: artifacts)
            do {
                try await body(input)
            } catch {
                throw try failed(error, iteration: iteration, input: input, artifacts: artifacts)
            }
            iteration += 1
        }
        return inputs.count + iteration
    }
}

extension FuzzRun {
    /// Fails the current iteration when `condition` is false: a property test's assertion. It
    /// throws instead of recording an issue, so the same body traps a libFuzzer target
    /// and the run keeps the input.
    public static func check(
        _ condition: Bool, _ message: @autoclosure () -> String = "", fileID: String = #fileID, line: Int = #line
    ) throws(FuzzError) {
        guard !condition else { return }
        let text = message()
        throw FuzzError.property(text.isEmpty ? "a property does not hold" : text, location: "\(fileID):\(line)")
    }
}
