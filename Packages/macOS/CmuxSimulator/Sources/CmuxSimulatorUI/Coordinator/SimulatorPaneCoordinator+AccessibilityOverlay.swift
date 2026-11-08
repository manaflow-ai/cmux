import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Enables a bounded live accessibility overlay and refreshes its snapshot
    /// once per second while enabled.
    public func setAccessibilityOverlayEnabled(_ enabled: Bool) {
        guard accessibilityOverlayEnabled != enabled else { return }
        accessibilityOverlayEnabled = enabled
        accessibilityOverlaySelectedNodeID = nil
        suspendAccessibilityOverlayRefresh()
        startAccessibilityOverlayRefreshIfNeeded()
    }

    /// Suspends automatic accessibility reads for hidden panes and resumes
    /// them when the pane becomes visible again without losing the toggle.
    public func setAccessibilityOverlayVisibility(_ isVisible: Bool) {
        guard accessibilityOverlayIsVisible != isVisible else { return }
        accessibilityOverlayIsVisible = isVisible
        if isVisible {
            startAccessibilityOverlayRefreshIfNeeded()
        } else {
            _ = suspendAccessibilityOverlayRefresh()
        }
    }

    func selectAccessibilityOverlayNode(_ node: SimulatorAccessibilityNode) {
        accessibilityOverlaySelectedNodeID = node.id
    }

    private func startAccessibilityOverlayRefreshIfNeeded() {
        guard !closed, accessibilityOverlayEnabled, accessibilityOverlayIsVisible,
              accessibilityRefreshTask == nil else { return }

        let sleeper = webInspectorSleeper
        let generation = accessibilityRefreshGeneration
        accessibilityRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.accessibilityOverlayEnabled,
                      self.accessibilityOverlayIsVisible,
                      self.accessibilityRefreshGeneration == generation else { return }
                let succeeded = await self.refreshAccessibilityForOverlay(generation: generation)
                do {
                    try await sleeper.sleep(for: succeeded ? .seconds(1) : .seconds(5))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshAccessibilityForOverlay(generation: UInt64) async -> Bool {
        let selectionGeneration = selectionGeneration
        do {
            let result = try await client.perform(.readAccessibility)
            guard !Task.isCancelled, !closed,
                  accessibilityRefreshGeneration == generation,
                  selectionGeneration == self.selectionGeneration,
                  case let .accessibility(snapshot) = result else { return false }
            applyAccessibilitySnapshot(snapshot)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func suspendAccessibilityOverlayRefresh() -> Task<Void, Never>? {
        accessibilityRefreshGeneration &+= 1
        let task = accessibilityRefreshTask
        task?.cancel()
        accessibilityRefreshTask = nil
        return task
    }

    @discardableResult
    func stopAccessibilityOverlayRefresh() -> Task<Void, Never>? {
        accessibilityOverlayEnabled = false
        accessibilityOverlaySelectedNodeID = nil
        return suspendAccessibilityOverlayRefresh()
    }
}
