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
            var rng = generator(for: iteration)
            let input = mutatedInput(inputs, mutator: mutator, using: &rng)
            try note(iteration: iteration, input: input, artifacts: artifacts)
            try attempt(iteration: iteration, input: input, artifacts: artifacts) { try body(input) }
            iteration += 1
        }
        return inputs.count + iteration
    }

    /// `forEach(_:)` with a body that awaits (an actor, a decoder that reads through an async
    /// transport): the same iterations, generators, long mode, in-flight files and failure, so a seed
    /// and an iteration name the same input in both. The body runs in the caller's isolation. A
    /// libFuzzer target cannot await, so a suite on this run has no libFuzzer wrapper (p10-stability-182).
    @discardableResult
    public func forEachAsync(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (inout FuzzRNG) async throws -> Void
    ) async throws(FuzzError) -> Int {
        let artifacts = try openArtifacts()
        defer { artifacts?.finish() }
        let deadline = self.deadline()
        var iteration = 0
        while continues(after: iteration, deadline: deadline) {
            var rng = generator(for: iteration)
            try note(iteration: iteration, input: nil, artifacts: artifacts)
            try await attemptAsync(iteration: iteration, input: nil, artifacts: artifacts) { try await body(&rng) }
            iteration += 1
        }
        return iteration
    }

    /// `forEachInput(_:mutator:_:)` with a body that awaits: the same corpus inputs, then the same
    /// mutated input per iteration. Returns the number of inputs run.
    @discardableResult
    public func forEachInputAsync(
        _ corpus: FuzzCorpus, mutator: FuzzMutator = FuzzMutator(),
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Data) async throws -> Void
    ) async throws(FuzzError) -> Int {
        let artifacts = try openArtifacts()
        defer { artifacts?.finish() }
        let inputs = corpus.inputs
        for (index, input) in inputs.enumerated() {
            try note(iteration: -1 - index, input: input, artifacts: artifacts)
            try await attemptAsync(iteration: -1 - index, input: input, artifacts: artifacts) { try await body(input) }
        }
        let deadline = self.deadline()
        var iteration = 0
        while continues(after: iteration, deadline: deadline) {
            var rng = generator(for: iteration)
            let input = mutatedInput(inputs, mutator: mutator, using: &rng)
            try note(iteration: iteration, input: input, artifacts: artifacts)
            try await attemptAsync(iteration: iteration, input: input, artifacts: artifacts) { try await body(input) }
            iteration += 1
        }
        return inputs.count + iteration
    }

    /// The generator of iteration `iteration`.
    public func generator(for iteration: Int) -> FuzzRNG {
        FuzzRNG(seed: FuzzRNG.derivedSeed(seed, stream: UInt64(truncatingIfNeeded: iteration)))
    }

    // MARK: - Driving

    /// An iteration's input: a corpus input, or random bytes one time in eight and whenever the
    /// corpus is empty, after a mutation pass that may cross it with another corpus input.
    private func mutatedInput(_ inputs: [Data], mutator: FuzzMutator, using rng: inout FuzzRNG) -> Data {
        let base = inputs.isEmpty || rng.oneIn(8) ? rng.bytes(256) : inputs[rng.below(inputs.count)]
        let partner = inputs.isEmpty ? nil : inputs[rng.below(inputs.count)]
        return mutator.mutate(base, crossingWith: partner, using: &rng)
    }

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
            throw try failure(iteration: iteration, input: input, error: error, artifacts: artifacts)
        }
    }

    private func attemptAsync(
        iteration: Int, input: Data?, artifacts: FuzzArtifacts?,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> Void
    ) async throws(FuzzError) {
        do {
            try await body()
        } catch {
            throw try failure(iteration: iteration, input: input, error: error, artifacts: artifacts)
        }
    }

    /// The failure of `iteration`, its input kept under `CMUX_FUZZ_ARTIFACTS`.
    private func failure(
        iteration: Int, input: Data?, error: any Error, artifacts: FuzzArtifacts?
    ) throws(FuzzError) -> FuzzError {
        var failure = FuzzFailure(
            name: name, seed: seed, iteration: iteration, input: input,
            reason: String(describing: error), artifact: nil, corpus: environment.corpus
        )
        failure.artifact = try artifacts?.keep(failure)
        return .failed(failure)
    }
}

extension FuzzRun {
    /// Fails the current iteration when `condition` is false: a property test's assertion. It
    /// throws instead of recording an issue, so the same body traps a libFuzzer target
    /// (p10-stability-182) and the run keeps the input.
    public static func check(
        _ condition: Bool, _ message: @autoclosure () -> String = "", fileID: String = #fileID, line: Int = #line
    ) throws(FuzzError) {
        guard !condition else { return }
        let text = message()
        throw FuzzError.property(text.isEmpty ? "a property does not hold" : text, location: "\(fileID):\(line)")
    }
}
