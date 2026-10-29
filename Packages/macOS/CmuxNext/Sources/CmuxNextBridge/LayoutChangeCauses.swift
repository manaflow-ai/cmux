public import CmuxNextDaemon
public import CmuxNextWakeups
import Observation

/// The highest cause of one workspace's layout tree changes since the owner last applied it
/// (feature `automationBurstSnap`). It changes no scheduling: the owner still
/// applies on its own observation's hop, where ``ObservationCauses/currentCause`` is gone, and
/// asks this recorder who caused what it applies, so an agent's burst of splits lands with no spring.
///
/// It records at Observation's will-set, in the turn of the change (the daemon store's drain sets
/// the cause per envelope, an action run per origin), and reads only the workspace's screens and
/// each screen's tree keys, O(screens), never the mapping. Until the cause is person (the highest),
/// that turn arms it again with the same read, so a higher cause before the apply raises it. One
/// tracking is armed at a time.
///
/// ```swift
/// let causes = LayoutChangeCauses(workspace, causes: services.mainWork.causes)
/// for await result in later { apply(result, cause: causes.take() ?? .program) }
/// ```
@MainActor
public final class LayoutChangeCauses {
    private let workspace: WorkspaceModel
    private let causes: ObservationCauses
    /// The highest cause since the last ``take()``; nil while no tree change was seen.
    private var pending: ObservationCause?
    /// A tracking is registered; its callback names ``generation``.
    private var armed = false
    private var generation: UInt64 = 0
    private var cancelled = false

    /// - Parameters:
    ///   - workspace: The workspace whose tree it follows.
    ///   - causes: The app's causes (`MainWorkScheduler.causes`): the cause of each change.
    public init(_ workspace: WorkspaceModel, causes: ObservationCauses) {
        self.workspace = workspace
        self.causes = causes
        arm()
    }

    /// The highest cause of the tree changes since the last call, nil when there was none; resets it.
    public func take() -> ObservationCause? {
        defer {
            pending = nil
            if !armed, !cancelled { arm() }
        }
        return pending
    }

    /// Records no more. The armed tracking fires once more at the next change and does nothing.
    public func cancel() {
        cancelled = true
        generation &+= 1
        pending = nil
    }

    private func arm() {
        generation &+= 1
        armed = true
        let armedGeneration = generation, workspace = workspace
        // view-observation-allow: records the cause in the change's turn and applies nothing; the owner's own observation applies
        withObservationTracking {
            for screen in workspace.screens {
                _ = screen.layout
                _ = screen.columns
                _ = screen.zoomedPane
            }
        } onChange: { @Sendable [weak self] in
            // main-hop-allow: the store changes on main, so this runs inline in the change's turn, where its cause is current
            MainDelivery().run { [weak self] in self?.changed(armedGeneration) }
        }
    }

    private func changed(_ armedGeneration: UInt64) { // perf-hot: 0.01ms frame-tick (each tree will-set; O(screens))
        guard !cancelled, armedGeneration == generation else { return }
        armed = false
        let cause = causes.currentCause
        pending = max(pending ?? cause, cause)
        // Only a higher cause changes what it records; person is the highest.
        if pending != .person { arm() }
    }
}
