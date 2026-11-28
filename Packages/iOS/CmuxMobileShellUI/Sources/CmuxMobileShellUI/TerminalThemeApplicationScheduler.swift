#if canImport(UIKit)
import Foundation

/// Keeps one latest-only pending surface theme and bounds expensive Ghostty
/// config applications during rapid OSC palette changes.
@MainActor
final class TerminalThemeApplicationScheduler {
    private let clock = ContinuousClock()
    private let minimumApplicationInterval: Duration
    private var applicationTask: Task<Void, Never>?
    private var pendingApplication: (@MainActor () -> Void)?
    private var lastApplicationInstant: ContinuousClock.Instant?
    private(set) var pendingGeneration: UInt64?
    private(set) var lastAppliedGeneration: UInt64 = 0

    init(minimumApplicationInterval: Duration = .milliseconds(100)) {
        self.minimumApplicationInterval = minimumApplicationInterval
    }

    func seed(generation: UInt64) {
        lastAppliedGeneration = generation
        lastApplicationInstant = clock.now
    }

    func schedule(
        generation: UInt64,
        application: @escaping @MainActor () -> Void
    ) {
        guard generation != lastAppliedGeneration,
              generation != pendingGeneration else { return }
        pendingGeneration = generation
        pendingApplication = application
        guard applicationTask == nil else { return }
        applicationTask = Task { @MainActor [weak self] in
            await self?.drainApplications()
        }
    }

    private func drainApplications() async {
        while pendingApplication != nil {
            if let lastApplicationInstant {
                let deadline = lastApplicationInstant.advanced(by: minimumApplicationInterval)
                if clock.now < deadline {
                    do {
                        try await clock.sleep(until: deadline)
                    } catch {
                        return
                    }
                }
            }
            guard !Task.isCancelled,
                  let generation = pendingGeneration,
                  let application = pendingApplication else { return }
            pendingGeneration = nil
            pendingApplication = nil
            lastAppliedGeneration = generation
            application()
            lastApplicationInstant = clock.now
        }
        applicationTask = nil
    }

    func cancel() {
        applicationTask?.cancel()
        applicationTask = nil
        pendingGeneration = nil
        pendingApplication = nil
    }
}
#endif
