#if canImport(UIKit)
import CmuxMobileDiagnostics
import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.surface.free")

@MainActor
final class SurfaceFreeDrainWatchdog {
    private let clock: ContinuousClock
    private let deadline: Duration
    private var tasks: [UInt64: Task<Void, Never>] = [:]

    init(clock: ContinuousClock = ContinuousClock(), deadline: Duration = .seconds(10)) {
        self.clock = clock
        self.deadline = deadline
    }

    func start(
        generation: UInt64,
        pendingFrees: @MainActor @escaping @Sendable () -> Int,
        onStuck: @MainActor @escaping @Sendable (_ generation: UInt64, _ pendingFrees: Int) -> Void = { generation, pendingFrees in
            MobileDebugLog.anchormux("surface.free.STUCK generation=\(generation) pendingFrees=\(pendingFrees)")
            log.fault("surface.free.STUCK generation=\(generation, privacy: .public) pendingFrees=\(pendingFrees, privacy: .public)")
        }
    ) {
        cancel(generation: generation)
        let clock = clock
        let deadline = deadline
        tasks[generation] = Task { @MainActor in
            do {
                // Genuine free-drain deadline; cancellation is tied to the free completion.
                try await clock.sleep(for: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            tasks[generation] = nil
            onStuck(generation, pendingFrees())
        }
    }

    func cancel(generation: UInt64) {
        tasks.removeValue(forKey: generation)?.cancel()
    }

}
#endif
