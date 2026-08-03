import CmuxUpdater
import Observation

/// Drives native update controls from the observable update model.
///
/// macOS 26 uses transactional `Observations`. The compatibility path rearms
/// `withObservationTracking` after each mutation while preserving main-actor delivery.
@MainActor
final class UpdatePresentationObserver {
    private weak var model: UpdateStateModel?
    private let apply: @MainActor () -> Void
    private var observationTask: Task<Void, Never>?
    private var legacyGeneration: UInt64 = 0
    private var isCancelled = false

    init(model: UpdateStateModel, apply: @MainActor @escaping () -> Void) {
        self.model = model
        self.apply = apply
        apply()

        if #available(macOS 26.0, *) {
            observationTask = Task { @MainActor [weak self, weak model] in
                guard let model else { return }
                let revisions = Observations { model.presentationRevision }
                for await _ in revisions {
                    guard !Task.isCancelled, let self, !self.isCancelled else { return }
                    self.apply()
                }
            }
        } else {
            armLegacyObservation()
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        legacyGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil
    }

    private func armLegacyObservation() {
        guard !isCancelled, let model else { return }
        legacyGeneration &+= 1
        let generation = legacyGeneration
        withObservationTracking {
            _ = model.presentationRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isCancelled,
                      self.legacyGeneration == generation else { return }
                self.apply()
                self.armLegacyObservation()
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }
}
