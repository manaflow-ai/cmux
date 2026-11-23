import AppKit
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// The card's Automations block (issue 25573): reading the Chief's automations from its brain and
/// sending a Pause, Resume or Delete.
extension HomeChiefSettingsView {
    /// Whether the block shows: only for a brain that keeps automations.
    var showsAutomations: Bool {
        get { !automationRows.isHidden }
        set {
            guard automationRows.isHidden == newValue else { return }
            automationsHeader.isHidden = !newValue
            automationRows.isHidden = !newValue
            onResize()
        }
    }

    /// Reads the automations off the main actor, then shows them; a brain that keeps none, or
    /// that does not answer (the engine note says why), hides the block.
    @discardableResult
    func refreshAutomations() -> Task<Void, Never> {
        let source = source
        // task-owner: one read off the main actor; ends when it is shown
        return Task { [weak self] in
            let result = await Self.automationResult { () async throws(HomeChiefEngineError) in try await source.automations() }
            guard let self, isShowing(source) else { return }
            showAutomations(result)
        }
    }

    /// Pauses, resumes or deletes automation `id` on the brain, then shows the list after it.
    @discardableResult
    func changeAutomation(_ id: String, _ action: ChiefAutomationAction) -> Task<Void, Never> {
        let source = source
        changeFailed = false
        // task-owner: one write off the main actor; ends when its result is shown
        return Task { [weak self] in
            let result = await Self.automationResult { () async throws(HomeChiefEngineError) in
                try await source.updateAutomation(id, action)
            }
            guard let self, isShowing(source) else { return }
            if case .failure(let error) = result {
                note(error.text, kept: true)
                return
            }
            // A change that took clears the note an earlier one left.
            if !failure.isHidden { hideNote(resize: false) }
            showAutomations(result)
        }
    }

    private func showAutomations(_ result: Result<[ChiefAutomation], HomeChiefEngineError>) {
        switch result {
        case .success(let automations):
            automationRows.show(automations)
            showsAutomations = true
            onResize()
        case .failure:
            showsAutomations = false
        }
    }

    /// Whether `source` is still the Chief this card shows (another conversation, or its other
    /// host, may have taken its place while a request ran).
    private func isShowing(_ source: any HomeChiefEngineSource) -> Bool {
        self.source.isLocal == source.isLocal && self.source.place == source.place
            && ObjectIdentifier(type(of: self.source)) == ObjectIdentifier(type(of: source))
    }

    /// Runs `body` off the main actor.
    private nonisolated static func automationResult(
        _ body: @escaping @Sendable () async throws(HomeChiefEngineError) -> [ChiefAutomation]
    ) async -> Result<[ChiefAutomation], HomeChiefEngineError> {
        // The card shows the answer: a person looks at it, nothing waits on a key for it.
        await Task.detached(priority: WorkPriority.userVisible.taskPriority) { () async -> Result<[ChiefAutomation], HomeChiefEngineError> in
            do throws(HomeChiefEngineError) { return .success(try await body()) } catch { return .failure(error) }
        }.value
    }
}
