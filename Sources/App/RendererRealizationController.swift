import AppKit
import Foundation

/// One terminal surface's state for the renderer-reclamation decision.
struct RendererRealizationPlannerInput: Sendable {
    let surfaceId: UUID
    let isVisible: Bool
    let isRealized: Bool
    let lastVisibleAt: TimeInterval
}

/// Pure policy for which offscreen terminal surfaces should release their GPU
/// renderer. Keeps the `maxWarmRenderers` most-recently-visible realized
/// surfaces warm (so switching among a working set stays instant), and releases
/// the rest only when they are offscreen and have been idle past `idleSeconds`.
/// A currently-visible surface is never selected.
enum RendererRealizationPlanner {
    static func selectedSurfaceIds(
        inputs: [RendererRealizationPlannerInput],
        settings: RendererRealizationSettings.Values,
        now: TimeInterval
    ) -> Set<UUID> {
        guard settings.enabled else { return [] }

        // Only realized surfaces hold releasable GPU resources. Rank by recency
        // (most-recent first); visible surfaces are stamped ~now so they sort to
        // the top and land inside the warm set.
        let ranked = inputs
            .filter { $0.isRealized }
            .sorted { lhs, rhs in
                if lhs.lastVisibleAt == rhs.lastVisibleAt {
                    return lhs.surfaceId.uuidString < rhs.surfaceId.uuidString
                }
                return lhs.lastVisibleAt > rhs.lastVisibleAt
            }

        let warmCap = max(1, settings.maxWarmRenderers)
        var selected: Set<UUID> = []
        for (index, input) in ranked.enumerated() {
            if index < warmCap { continue }          // keep the most-recent N warm
            if input.isVisible { continue }          // never release a visible surface
            guard now - input.lastVisibleAt >= settings.idleSeconds else { continue }
            selected.insert(input.surfaceId)
        }
        return selected
    }
}

/// Periodically releases the GPU renderer (Metal swap chain / IOSurface, ~40MB
/// each) of terminal surfaces that have been offscreen and idle, while keeping
/// their PTY and terminal state alive. The renderer is rebuilt on re-show via
/// `TerminalSurface.realizeRenderer()` driven from `setVisibleInUI(true)`.
///
/// macOS-only (AppKit). Sibling of `AgentHibernationController`, but
/// non-destructive: no process is killed, so it is safe to default ON.
@MainActor
final class RendererRealizationController {
    static let shared = RendererRealizationController()

    private let timerQueue = DispatchQueue(label: "com.cmux.renderer-realization", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var settingsObserver: NSObjectProtocol?

    private init() {}

    func start() {
        guard settingsObserver == nil else {
            updateTimerForCurrentSettings()
            return
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: RendererRealizationSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                RendererRealizationController.shared.updateTimerForCurrentSettings()
            }
        }
        updateTimerForCurrentSettings()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
    }

    private func updateTimerForCurrentSettings() {
        guard RendererRealizationSettings.isEnabled() else {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 10, repeating: 20)
        timer.setEventHandler {
            let now = Date()
            Task { @MainActor in
                RendererRealizationController.shared.evaluate(now: now)
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// Run one reclamation pass. Internal so a unit/integration test can drive it
    /// deterministically without the timer.
    func evaluate(now: Date) {
        let settings = RendererRealizationSettings.values()
        guard settings.enabled else { return }
        guard let appDelegate = AppDelegate.shared else { return }

        let records = appDelegate.rendererRealizationRecords()

        // Stamp currently-visible surfaces so they rank at the top of the warm
        // set (a continuously-visible surface might otherwise carry a stale
        // timestamp). The planner also protects visible surfaces explicitly.
        for record in records where record.isVisible {
            record.surface.noteBecameVisibleForRendererReclamation()
        }

        let inputs = records.compactMap { record -> RendererRealizationPlannerInput? in
            guard record.surface.hasLiveSurface else { return nil }
            return RendererRealizationPlannerInput(
                surfaceId: record.surface.id,
                isVisible: record.isVisible,
                isRealized: record.surface.isRendererRealized,
                lastVisibleAt: record.surface.rendererLastVisibleAt
            )
        }

        let selected = RendererRealizationPlanner.selectedSurfaceIds(
            inputs: inputs,
            settings: settings,
            now: now.timeIntervalSince1970
        )
        guard !selected.isEmpty else { return }
        for record in records where selected.contains(record.surface.id) {
            record.surface.releaseRenderer()
        }
    }
}

extension AppDelegate {
    /// Every live terminal surface across all windows/workspaces, tagged with
    /// whether it is currently visible. Mirrors the visibility derivation in
    /// `agentHibernationRecords` but covers all terminals, not just resumable
    /// agents.
    @MainActor
    func rendererRealizationRecords() -> [(surface: TerminalSurface, isVisible: Bool)] {
        var records: [(surface: TerminalSurface, isVisible: Bool)] = []
        var seenManagers: Set<ObjectIdentifier> = []

        func visit(tabManager manager: TabManager, visibleWorkspaceId: UUID?) {
            let managerId = ObjectIdentifier(manager)
            guard seenManagers.insert(managerId).inserted else { return }
            for workspace in manager.tabs {
                let workspaceIsVisible = visibleWorkspaceId == workspace.id
                let visiblePanelIds = workspaceIsVisible
                    ? workspace.agentHibernationVisiblePanelIdsForCurrentLayout()
                    : []
                for (panelId, panel) in workspace.panels {
                    guard let terminalPanel = panel as? TerminalPanel else { continue }
                    let isVisible = workspaceIsVisible && visiblePanelIds.contains(panelId)
                    records.append((surface: terminalPanel.surface, isVisible: isVisible))
                }
            }
        }

        for context in mainWindowContexts.values {
            let visibleWorkspaceId = context.window?.isVisible == true ? context.tabManager.selectedTabId : nil
            visit(tabManager: context.tabManager, visibleWorkspaceId: visibleWorkspaceId)
        }
        if let tabManager {
            visit(tabManager: tabManager, visibleWorkspaceId: nil)
        }

        return records
    }
}
