@testable import CmuxUpdater

@MainActor
final class SuspendedRelaunchPreparationDelegate: UpdateActionDelegate {
    private let events: RelaunchPreparationEventQueue
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    private(set) var relaunchInvalidationCount = 0

    init(events: RelaunchPreparationEventQueue) {
        self.events = events
    }

    func updaterRequestsRetryCheckForUpdates() {}

    func updaterPreparesToRelaunchApplication() async {
        events.send(.preparationBegan)
        await withCheckedContinuation { continuation in
            preparationContinuation = continuation
        }
    }

    func updaterAbandonsRelaunchPreparation() {
        relaunchInvalidationCount += 1
    }

    func updaterWillRelaunchApplication() {}

    func finishPreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }
}
