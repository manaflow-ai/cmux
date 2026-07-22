import Foundation

@MainActor
final class MobileTerminalThemeInvalidationScheduler {
    private let delay: Duration
    private let clock: any Clock<Duration>
    private let handler: @MainActor (Set<UUID>) -> Void
    private var pendingSurfaceIDs = Set<UUID>()
    private var flushTask: Task<Void, Never>?

    init(
        delay: Duration = .milliseconds(100),
        clock: any Clock<Duration> = ContinuousClock(),
        handler: @escaping @MainActor (Set<UUID>) -> Void
    ) {
        self.delay = delay
        self.clock = clock
        self.handler = handler
    }

    func schedule(surfaceID: UUID) {
        pendingSurfaceIDs.insert(surfaceID)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self, clock, delay] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func cancel() {
        flushTask?.cancel()
        flushTask = nil
        pendingSurfaceIDs.removeAll()
    }

    private func flush() {
        flushTask = nil
        guard !pendingSurfaceIDs.isEmpty else { return }
        let surfaceIDs = pendingSurfaceIDs
        pendingSurfaceIDs.removeAll(keepingCapacity: true)
        handler(surfaceIDs)
    }
}
