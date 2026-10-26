import Foundation

/// `forEach` and `forEachInput` for a body that awaits: an actor, a decoder that reads
/// through an async transport. The iterations, their generators and inputs, long mode,
/// the in-flight files and the failure are those of the synchronous runs, so a seed and
/// an iteration name the same input in both. The body runs in the caller's isolation
/// (`#isolation`): a `@MainActor` suite passes a closure that touches main-actor state.
/// A libFuzzer target cannot await, so a suite on these runs has no Linux libFuzzer
/// wrapper (p10-stability-182); its `oneInput(_:)` still replays a choice tape here.
extension FuzzRun {
    /// `forEach(_:)` with a body that awaits; returns the iteration count.
    @discardableResult
    public func forEachAsync(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (inout FuzzRNG) async throws -> Void
    ) async throws(FuzzError) -> Int {
        let artifacts = try asyncArtifacts()
        defer { artifacts?.finish() }
        let deadline = asyncDeadline()
        var iteration = 0
        while asyncContinues(after: iteration, deadline: deadline) {
            var rng = generator(for: iteration)
            try asyncNote(iteration: iteration, input: nil, artifacts: artifacts)
            do {
                try await body(&rng)
            } catch {
                throw try asyncFailure(iteration: iteration, input: nil, error: error, artifacts: artifacts)
            }
            iteration += 1
        }
        return iteration
    }

    /// `forEachInput(_:mutator:_:)` with a body that awaits: the corpus inputs as they are,
    /// then one mutated input per iteration, chosen as the synchronous run chooses it.
    /// Returns the number of inputs run.
    @discardableResult
    public func forEachInputAsync(
        _ corpus: FuzzCorpus, mutator: FuzzMutator = FuzzMutator(),
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Data) async throws -> Void
    ) async throws(FuzzError) -> Int {
        let artifacts = try asyncArtifacts()
        defer { artifacts?.finish() }
        let inputs = corpus.inputs
        for (index, input) in inputs.enumerated() {
            try await asyncAttempt(iteration: -1 - index, input: input, artifacts: artifacts, body)
        }
        let deadline = asyncDeadline()
        var iteration = 0
        while asyncContinues(after: iteration, deadline: deadline) {
            var rng = generator(for: iteration)
            let base = inputs.isEmpty || rng.oneIn(8) ? rng.bytes(256) : inputs[rng.below(inputs.count)]
            let partner = inputs.isEmpty ? nil : inputs[rng.below(inputs.count)]
            let input = mutator.mutate(base, crossingWith: partner, using: &rng)
            try await asyncAttempt(iteration: iteration, input: input, artifacts: artifacts, body)
            iteration += 1
        }
        return inputs.count + iteration
    }

    // MARK: - Driving

    private func asyncAttempt(
        iteration: Int, input: Data, artifacts: FuzzArtifacts?,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Data) async throws -> Void
    ) async throws(FuzzError) {
        try asyncNote(iteration: iteration, input: input, artifacts: artifacts)
        do {
            try await body(input)
        } catch {
            throw try asyncFailure(iteration: iteration, input: input, error: error, artifacts: artifacts)
        }
    }

    private func asyncDeadline() -> ContinuousClock.Instant? {
        guard let budget = environment.longModeBudget(from: Date()) else { return nil }
        return ContinuousClock.now.advanced(by: .seconds(min(budget, 1e9)))
    }

    private func asyncContinues(after iteration: Int, deadline: ContinuousClock.Instant?) -> Bool {
        if iteration < iterations { return true }
        guard let deadline else { return false }
        return ContinuousClock.now < deadline
    }

    private func asyncArtifacts() throws(FuzzError) -> FuzzArtifacts? {
        guard let directory = environment.artifacts else { return nil }
        return try FuzzArtifacts(directory: directory, name: name)
    }

    private func asyncNote(iteration: Int, input: Data?, artifacts: FuzzArtifacts?) throws(FuzzError) {
        guard let artifacts else { return }
        let replay = FuzzFailure.replayLine(name: name, seed: seed, iteration: iteration, corpus: environment.corpus)
        try artifacts.noteInflight(seed: seed, iteration: iteration, replay: replay, input: input)
    }

    /// The failure of `iteration`, its input kept under `CMUX_FUZZ_ARTIFACTS`.
    private func asyncFailure(
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
