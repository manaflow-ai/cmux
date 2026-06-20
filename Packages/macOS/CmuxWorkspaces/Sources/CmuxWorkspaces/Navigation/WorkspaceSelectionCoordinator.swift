public import Foundation

/// Sequences the per-window workspace *selection navigation* gestures the
/// legacy `TabManager` god object owned inline: cycle to the next / previous
/// workspace (wrapping the tab order), select by index, select the last
/// workspace, and the workspace-cycle "hot" window that widens the
/// background-mount budget for the ~220 ms a rapid cycle lasts.
///
/// The coordinator owns the *order math* (the wrap-around index computation
/// against the window's ``WorkspacesModel`` tab order) and the cycle-hot state
/// machine (generation counter + cooldown task + the ``BackgroundWorkspaceLoadModel``
/// `isWorkspaceCycleHot` flag). Every irreducible app-coupled effect inverts
/// through ``WorkspaceSelectionHosting``: the actual selection mutation (the
/// legacy private `selectWorkspaceId(_:notificationDismissalContext:)`, which
/// sets `selectedTabId` and runs the full selection side-effect chain), the
/// keyboard-nav sidebar multi-selection collapse, and the DEBUG switch tracing.
///
/// Every navigation entry point selects with the **same** notification-dismissal
/// context the legacy code used (`.explicitWorkspaceResume`), so the host's
/// ``WorkspaceSelectionHosting/selectWorkspaceFromNavigation(id:)`` bakes that
/// context in and the package never needs the `NotificationDismissalContext`
/// enum (owned by a sibling package) — keeping this lift free of a new
/// cross-package edge.
///
/// `@MainActor` because every entry point is a keyboard/menu/CLI gesture on the
/// main actor and the model, the background-load model, and the host all live
/// there; co-locating removes any bridging (mirrors the sibling workspace
/// coordinators' isolation ruling). The cooldown uses a `Task` + `Task.sleep`
/// guarded by a generation token exactly as the legacy code did; this is a
/// byte-identical lift, so the raw `Task.sleep` is preserved rather than
/// modernized onto an injected clock.
@MainActor
public final class WorkspaceSelectionCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>
    private let backgroundLoad: BackgroundWorkspaceLoadModel
    private weak var host: (any WorkspaceSelectionHosting)?

    /// Monotonic token identifying the most recent cycle-hot activation; the
    /// cooldown task only clears the hot flag when its captured generation is
    /// still current (legacy `workspaceCycleGeneration`).
    private var workspaceCycleGeneration: UInt64 = 0

    /// The in-flight cooldown that flips `isWorkspaceCycleHot` back off after the
    /// cycle settles (legacy `workspaceCycleCooldownTask`).
    private var workspaceCycleCooldownTask: Task<Void, Never>?

    /// Creates the coordinator over the window's workspace-list model and its
    /// background-workspace-load / cycle-hot model.
    public init(
        model: WorkspacesModel<Tab>,
        backgroundLoad: BackgroundWorkspaceLoadModel
    ) {
        self.model = model
        self.backgroundLoad = backgroundLoad
    }

    /// Attaches the window-side host that performs the app-coupled selection
    /// effects. Must be called before the first navigation gesture.
    public func attach(host: any WorkspaceSelectionHosting) {
        self.host = host
    }

    // MARK: - Cycle navigation (legacy selectNextTab / selectPreviousTab)

    /// Selects the next workspace in the tab order, wrapping to the first
    /// (legacy `TabManager.selectNextTab`). No-op when there is no current
    /// selection or the selection is not in `tabs`.
    public func selectNextTab() {
        guard let currentId = model.selectedTabId,
              let currentIndex = model.tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % model.tabs.count
        let nextId = model.tabs[nextIndex].id
        host?.debugPrepareWorkspaceSwitch(trigger: "next", from: currentId, to: nextId)
        activateWorkspaceCycleHotWindow()
        host?.selectWorkspaceFromNavigation(id: nextId)
        // Keyboard nav is an explicit "focus one workspace" gesture, so drop
        // any stale sidebar multi-selection (Shift-click range) so subsequent
        // batch actions don't operate on workspaces the user thought they
        // had unselected by moving on.
        host?.collapseSidebarMultiSelection(except: nextId)
    }

    /// Selects the previous workspace in the tab order, wrapping to the last
    /// (legacy `TabManager.selectPreviousTab`). No-op when there is no current
    /// selection or the selection is not in `tabs`.
    public func selectPreviousTab() {
        guard let currentId = model.selectedTabId,
              let currentIndex = model.tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + model.tabs.count) % model.tabs.count
        let prevId = model.tabs[prevIndex].id
        host?.debugPrepareWorkspaceSwitch(trigger: "prev", from: currentId, to: prevId)
        activateWorkspaceCycleHotWindow()
        host?.selectWorkspaceFromNavigation(id: prevId)
        host?.collapseSidebarMultiSelection(except: prevId)
    }

    // MARK: - Direct selection (legacy selectTab(at:) / selectLastTab)

    /// Selects the workspace at `index` in the tab order, ignoring out-of-range
    /// indices (legacy `TabManager.selectTab(at:)`).
    public func selectTab(at index: Int) {
        guard index >= 0 && index < model.tabs.count else { return }
        let targetId = model.tabs[index].id
        host?.debugPrimeWorkspaceSwitch(trigger: "select_index", to: targetId)
        host?.selectWorkspaceFromNavigation(id: targetId)
    }

    /// Selects the last workspace in the tab order (legacy
    /// `TabManager.selectLastTab`). No-op when there are no workspaces.
    public func selectLastTab() {
        guard let lastTab = model.tabs.last else { return }
        host?.selectWorkspaceFromNavigation(id: lastTab.id)
    }

    // MARK: - Cycle-hot window (legacy activateWorkspaceCycleHotWindow)

    /// Marks the window "cycle hot" — widening the background-mount budget so a
    /// rapid next/prev cycle keeps the adjacent workspaces warm — and arms a
    /// generation-guarded cooldown that flips the flag back off ~220 ms after the
    /// last activation (legacy `TabManager.activateWorkspaceCycleHotWindow`).
    ///
    /// Each call bumps the generation and cancels any pending cooldown, so a
    /// burst of cycles holds the window hot until the burst settles. The cooldown
    /// only clears the flag if its captured generation is still current, which
    /// absorbs both the cancel-during-sleep race and any stale post-sleep fire.
    public func activateWorkspaceCycleHotWindow() {
        workspaceCycleGeneration &+= 1
        let generation = workspaceCycleGeneration
        if !backgroundLoad.isWorkspaceCycleHot {
            backgroundLoad.isWorkspaceCycleHot = true
            host?.debugLogWorkspaceCycleHotOn(generation: generation)
        }

        let hadPendingCooldown = workspaceCycleCooldownTask != nil
        workspaceCycleCooldownTask?.cancel()
        if hadPendingCooldown {
            host?.debugLogWorkspaceCycleHotCancelPrevious(generation: generation)
        }
        workspaceCycleCooldownTask = Task { [weak self, generation] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.host?.debugLogWorkspaceCycleHotCooldownCanceled(generation: generation)
                }
                return
            }
            await MainActor.run {
                guard let self else { return }
                guard self.workspaceCycleGeneration == generation else { return }
                self.host?.debugLogWorkspaceCycleHotOff(generation: generation)
                self.backgroundLoad.isWorkspaceCycleHot = false
                self.workspaceCycleCooldownTask = nil
            }
        }
    }

    /// Cancels any in-flight cooldown and clears the hot flag (legacy
    /// `TabManager` teardown / reset path). Idempotent.
    public func resetWorkspaceCycleHotWindow() {
        workspaceCycleCooldownTask?.cancel()
        workspaceCycleCooldownTask = nil
        backgroundLoad.isWorkspaceCycleHot = false
    }
}
