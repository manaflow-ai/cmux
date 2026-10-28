import Foundation

/// Owns one person-initiated creation handoff while hosted Cloud sign-in is pending.
/// A replacement click or cancellation invalidates the previous generation, so a
/// late auth callback cannot create a second machine or replay an old request.
@MainActor
final class CloudSignedOutCreationContinuation {
    private var generation = 0
    private var task: Task<Void, Never>?

    func replace(
        signIn: @escaping @MainActor () async -> Bool,
        resume: @escaping @MainActor () -> Void
    ) {
        generation += 1
        let expected = generation
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await signIn(), !Task.isCancelled, self.generation == expected else { return }
            resume()
            if self.generation == expected { self.task = nil }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    var isPending: Bool { task != nil }
}
