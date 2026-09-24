import CmuxFoundation
import CmuxWorkspaces
import Foundation

/// A restore owner (Workspace or Dock) that holds launches until the live-agent index can decide ownership.
///
/// Restore is synchronous because it rebuilds Bonsplit topology, while the
/// live-agent index is intentionally asynchronous. Keeping the request on the
/// owner lets the terminal join its topology first and avoids a main-actor
/// hook-store scan. Each owner supplies admission for its own panels; the
/// retry loop below is shared so both follow one lifecycle.
@MainActor
protocol DeferredAgentResumeAdmissionOwner: AnyObject {
    var deferredAgentResumeRestoresByPanelId: [UUID: DeferredAgentResumeRestore] { get set }
    var deferredAgentResumeIndexTask: Task<Void, Never>? { get set }

    /// Admits, retains, or cancels each pending restore against a complete index.
    func resolveDeferredAgentResumeRestores(using index: RestorableAgentSessionIndex)
    /// Presents pending restores as still checking when no index is available.
    func presentPendingAgentResumeRestores()
    /// Fresh evidence for this owner's pending requests.
    var deferredAgentResumeIndexProvider: @MainActor @Sendable () async -> SharedLiveAgentIndexRefreshOutcome { get }
    /// Waits for the next evidence event; cancellation releases the wait.
    var deferredAgentResumeEvidenceWait: @Sendable () async -> Void { get }
}

extension DeferredAgentResumeAdmissionOwner {
    /// Defers one restore launch until the off-main shared agent index is ready.
    func deferAgentResumeRestore(
        panelId: UUID,
        restore: DeferredAgentResumeRestore
    ) {
        deferredAgentResumeRestoresByPanelId[panelId] = restore
        // A newly transferred pane is new work, even if the prior pass is
        // waiting on an unrelated owner's file or process event.
        deferredAgentResumeIndexTask?.cancel()
        let refresh = deferredAgentResumeIndexProvider
        let waitForEvidence = deferredAgentResumeEvidenceWait
        deferredAgentResumeIndexTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let outcome = await refresh()
                // Do not hold the owner across the evidence wait: teardown must
                // not be delayed by a restore that is still observing evidence.
                guard !Task.isCancelled,
                      self?.applyDeferredAgentResumeOutcome(outcome) == true else { return }
                await waitForEvidence()
            }
        }
    }

    var deferredAgentResumeIndexProvider: @MainActor @Sendable () async -> SharedLiveAgentIndexRefreshOutcome {
        { await SharedLiveAgentIndex.shared.indexForOwnershipDecision() }
    }

    var deferredAgentResumeEvidenceWait: @Sendable () async -> Void {
        {
            await AgentRestoreEvidenceObservation().wait(
                process: nil,
                paths: [RestorableAgentKind.claude.hookStoreFileURL().deletingLastPathComponent().path]
            )
        }
    }

    /// Applies one index outcome to every pending restore.
    /// - Returns: Whether restores remain pending and the loop should keep observing evidence.
    func applyDeferredAgentResumeOutcome(_ outcome: SharedLiveAgentIndexRefreshOutcome) -> Bool {
        switch outcome {
        case .index(let index):
            resolveDeferredAgentResumeRestores(using: index)
        case .timedOut, .cancelled:
            presentPendingAgentResumeRestores()
        }
        guard !deferredAgentResumeRestoresByPanelId.isEmpty else {
            deferredAgentResumeIndexTask = nil
            return false
        }
        return true
    }
}

extension Workspace: DeferredAgentResumeAdmissionOwner {}
extension DockSplitStore: DeferredAgentResumeAdmissionOwner {}
