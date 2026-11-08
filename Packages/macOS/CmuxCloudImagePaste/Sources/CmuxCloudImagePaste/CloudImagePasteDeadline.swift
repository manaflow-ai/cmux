/// Owns one cancellable upload deadline measured by the coordinator's clock.
final class CloudImagePasteDeadline: Sendable {
    private let task: Task<Void, Never>

    init(duration: Duration, clock: any Clock<Duration>, action: @escaping @MainActor @Sendable () -> Void) {
        task = Task { @MainActor in
            do { try await clock.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() { task.cancel() }

    deinit { task.cancel() }
}
