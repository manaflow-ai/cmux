internal import Foundation

/// Races a cancellable catalog transport with its bounded deadline without
/// making the catalog client own lock-based mutable state.
internal actor MobileTaskModelCatalogLoadCoordinator {
    private var completed = false
    private var continuation: CheckedContinuation<Data, any Error>?
    private var loaderTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(
        continuation: CheckedContinuation<Data, any Error>,
        endpoint: URL,
        loader: @escaping @Sendable (URL) async throws -> Data
    ) {
        guard !completed else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let loaderTask = Task { [weak self] in
            do {
                let data = try await loader(endpoint)
                await self?.finish(.success(data))
            } catch {
                await self?.finish(.failure(error))
            }
        }
        let timeoutTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(for: .seconds(10))
                await self?.finish(.failure(URLError(.timedOut)))
            } catch {
                // The loader completed first or the caller cancelled.
            }
        }
        self.loaderTask = loaderTask
        self.timeoutTask = timeoutTask
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard !completed else { return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let loaderTask = self.loaderTask
        self.loaderTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        loaderTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
