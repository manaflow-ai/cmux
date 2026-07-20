import Foundation
@testable import CmuxSidebarGit

/// An in-memory ``SidebarGitHosting`` fake: a tiny workspace/panel model plus
/// a recorded projection log and an `AsyncStream` of projection events so
/// tests can await the asynchronous apply paths deterministically.
@MainActor
final class RecordingSidebarGitHost: SidebarGitHosting {
    enum ProjectionEvent: Equatable {
        case panelDirectory(UUID, UUID, String)
        case gitBranch(UUID, UUID, String, Bool)
        case clearGitBranch(UUID, UUID)
        case pullRequestBadge(UUID, UUID, SidebarPullRequestBadge)
        case clearPullRequestBadge(UUID, UUID)
        case scheduleGitMetadataProbe(UUID, UUID, String)
        case clearAllGitMetadata
        case clearAllPullRequestMetadata
    }

    struct PanelState {
        var directory: String?
        var hasTrustedRemoteDirectory = false
        var branch: SidebarPanelGitBranch?
        var badge: SidebarPullRequestBadge?
        var isTerminal = true
        var isRemoteTerminal = false
    }

    struct WorkspaceState {
        var isRemote = false
        var panels: [UUID: PanelState] = [:]
        var focusedPanelId: UUID?
    }

    var workspaces: [(id: UUID, state: WorkspaceState)] = []
    var gitMetadataActivity: SidebarGitMetadataActivity = .activePolling
    var pullRequestActivity: SidebarGitMetadataActivity = .disabled
    var pollingEnabled: Bool {
        get { pullRequestActivity.performsActivePolling }
        set { pullRequestActivity = newValue ? .activePolling : .disabled }
    }
    var mobileHostActive = false
    var selectedWorkspaceId: UUID?
    private(set) var events: [ProjectionEvent] = []
    private var eventContinuations: [AsyncStream<ProjectionEvent>.Continuation] = []

    /// A stream of projection events, registered before the awaited action.
    func projectionEvents() -> AsyncStream<ProjectionEvent> {
        AsyncStream { continuation in
            eventContinuations.append(continuation)
        }
    }

    private func record(_ event: ProjectionEvent) {
        events.append(event)
        for continuation in eventContinuations {
            continuation.yield(event)
        }
    }

    @discardableResult
    func addWorkspace(panelDirectory: String?) -> (workspaceId: UUID, panelId: UUID) {
        let workspaceId = UUID()
        let panelId = UUID()
        var state = WorkspaceState()
        state.panels[panelId] = PanelState(directory: panelDirectory)
        state.focusedPanelId = panelId
        workspaces.append((workspaceId, state))
        return (workspaceId, panelId)
    }

    private func state(_ id: UUID) -> WorkspaceState? {
        workspaces.first(where: { $0.id == id })?.state
    }

    private func mutate(_ id: UUID, _ body: (inout WorkspaceState) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        body(&workspaces[index].state)
    }

    // MARK: Reads

    func orderedWorkspaceIds() -> [UUID] { workspaces.map(\.id) }
    func workspaceExists(_ workspaceId: UUID) -> Bool { state(workspaceId) != nil }
    func isRemoteWorkspace(_ workspaceId: UUID) -> Bool? { state(workspaceId)?.isRemote }
    func panelIds(in workspaceId: UUID) -> [UUID] {
        state(workspaceId).map { Array($0.panels.keys) } ?? []
    }
    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool {
        state(workspaceId)?.panels[panelId] != nil
    }
    func hasTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        state(workspaceId)?.panels[panelId]?.isTerminal ?? false
    }
    func isRemoteTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        state(workspaceId)?.panels[panelId]?.isRemoteTerminal ?? false
    }
    func gitProbeDirectory(workspaceId: UUID, panelId: UUID) -> String? {
        state(workspaceId)?.panels[panelId]?.directory?.nonEmptyNormalizedGitProbeDirectory
    }
    func hasTrustedRemotePanelDirectory(workspaceId: UUID, panelId: UUID) -> Bool {
        state(workspaceId)?.panels[panelId]?.hasTrustedRemoteDirectory ?? false
    }
    func panelGitBranch(workspaceId: UUID, panelId: UUID) -> SidebarPanelGitBranch? {
        state(workspaceId)?.panels[panelId]?.branch
    }
    func panelGitBranchPanelIds(in workspaceId: UUID) -> Set<UUID> {
        guard let state = state(workspaceId) else { return [] }
        return Set(state.panels.filter { $0.value.branch != nil }.keys)
    }
    func panelPullRequestBadge(workspaceId: UUID, panelId: UUID) -> SidebarPullRequestBadge? {
        state(workspaceId)?.panels[panelId]?.badge
    }
    func panelPullRequestPanelIds(in workspaceId: UUID) -> Set<UUID> {
        guard let state = state(workspaceId) else { return [] }
        return Set(state.panels.filter { $0.value.badge != nil }.keys)
    }
    func focusedPanelId(in workspaceId: UUID) -> UUID? {
        state(workspaceId)?.focusedPanelId
    }
    func hasWorkspaceLevelGitSignal(_ workspaceId: UUID) -> Bool {
        guard let state = state(workspaceId) else { return false }
        return state.panels.values.contains { $0.branch != nil || $0.badge != nil }
    }
    func isSelectedFocusedPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        selectedWorkspaceId == workspaceId && state(workspaceId)?.focusedPanelId == panelId
    }

    // MARK: Writes

    @discardableResult
    func updatePanelDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) -> Bool {
        guard state(workspaceId)?.panels[panelId] != nil else { return false }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        mutate(workspaceId) { $0.panels[panelId]?.directory = trimmed }
        record(.panelDirectory(workspaceId, panelId, trimmed))
        return true
    }

    @discardableResult
    func updateRemotePanelDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) -> Bool {
        guard updatePanelDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            displayLabel: displayLabel
        ) else { return false }
        mutate(workspaceId) { $0.panels[panelId]?.hasTrustedRemoteDirectory = true }
        return true
    }

    func updatePanelGitBranch(workspaceId: UUID, panelId: UUID, branch: String, isDirty: Bool) {
        mutate(workspaceId) {
            $0.panels[panelId]?.branch = SidebarPanelGitBranch(branch: branch, isDirty: isDirty)
        }
        record(.gitBranch(workspaceId, panelId, branch, isDirty))
    }

    func clearPanelGitBranch(workspaceId: UUID, panelId: UUID) {
        mutate(workspaceId) {
            $0.panels[panelId]?.branch = nil
            $0.panels[panelId]?.badge = nil
        }
        record(.clearGitBranch(workspaceId, panelId))
    }

    func updatePanelPullRequest(workspaceId: UUID, panelId: UUID, badge: SidebarPullRequestBadge) {
        mutate(workspaceId) { $0.panels[panelId]?.badge = badge }
        record(.pullRequestBadge(workspaceId, panelId, badge))
    }

    func clearPanelPullRequest(workspaceId: UUID, panelId: UUID) {
        mutate(workspaceId) { $0.panels[panelId]?.badge = nil }
        record(.clearPullRequestBadge(workspaceId, panelId))
    }

    func schedulePanelGitMetadataProbe(workspaceId: UUID, panelId: UUID, reason: String) {
        record(.scheduleGitMetadataProbe(workspaceId, panelId, reason))
    }

    func clearAllSidebarGitMetadata() {
        for index in workspaces.indices {
            for panelId in workspaces[index].state.panels.keys {
                workspaces[index].state.panels[panelId]?.branch = nil
                workspaces[index].state.panels[panelId]?.badge = nil
            }
        }
        record(.clearAllGitMetadata)
    }

    func clearAllSidebarPullRequestMetadata() {
        for index in workspaces.indices {
            for panelId in workspaces[index].state.panels.keys {
                workspaces[index].state.panels[panelId]?.badge = nil
            }
        }
        record(.clearAllPullRequestMetadata)
    }

    // MARK: Environment

    func mobileHostHasRecentActivity(within interval: TimeInterval) -> Bool { mobileHostActive }
    func mobileHostQuietDelay(for interval: TimeInterval) -> TimeInterval { mobileHostActive ? interval : 0 }
}
