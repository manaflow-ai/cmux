public import Combine
public import Foundation
public import Observation

/// The per-workspace sidebar-metadata sub-model: owns the sidebar status
/// entries, metadata blocks, log entries, progress, and git-branch /
/// pull-request presentation state the legacy `Workspace` god object kept as
/// loose Combine-backed stored state (`statusEntries`, `metadataBlocks`,
/// `logEntries`, `progress`, `gitBranch`, `panelGitBranches`, `pullRequest`,
/// `panelPullRequests`).
///
/// `Workspace` owns one instance and forwards each former stored property
/// through a computed `get`/`set` pair, so every call site (`statusEntries[key]
/// = …`, `logEntries.append(…)`, `workspace.progress`) stays byte-identical.
///
/// Byte-identical observer parity: the legacy properties used the old
/// Combine-backed observation path, and
/// the sidebar observation publishers (`Workspace.sidebarObservationPublisher`)
/// fused their `$projection`s through `CombineLatest` + `removeDuplicates()`.
/// To preserve that exactly, each property here mirrors its value into a
/// `CurrentValueSubject` in `didSet`; the matching `…Publisher` accessor
/// replaces the former `$property`. `CombineLatest` over current-value subjects
/// seeded with the initial values, then deduplicated, produces the identical
/// sequence of distinct fused states the old property projections did, so the
/// debounced sidebar refresh fires at the same moments.
@MainActor
@Observable
public final class WorkspaceSidebarMetadataModel {
    /// Sidebar status entries keyed by status key (legacy
    /// `Workspace.statusEntries`).
    public var statusEntries: [String: SidebarStatusEntry] = [:] {
        didSet { statusEntriesSubject.send(statusEntries) }
    }

    /// Sidebar markdown metadata blocks keyed by block key (legacy
    /// `Workspace.metadataBlocks`).
    public var metadataBlocks: [String: SidebarMetadataBlock] = [:] {
        didSet { metadataBlocksSubject.send(metadataBlocks) }
    }

    /// Recent sidebar log entries, oldest first, capped to the configured
    /// limit (legacy `Workspace.logEntries`).
    public var logEntries: [SidebarLogEntry] = [] {
        didSet { logEntriesSubject.send(logEntries) }
    }

    /// The current sidebar progress indicator, if any (legacy
    /// `Workspace.progress`).
    public var progress: SidebarProgressState? {
        didSet { progressSubject.send(progress) }
    }

    /// The workspace-level git branch state shown in the sidebar (legacy
    /// `Workspace.gitBranch`).
    public var gitBranch: SidebarGitBranchState? {
        didSet { gitBranchSubject.send(gitBranch) }
    }

    /// Per-panel git branch state keyed by panel id (legacy
    /// `Workspace.panelGitBranches`).
    public var panelGitBranches: [UUID: SidebarGitBranchState] = [:] {
        didSet { panelGitBranchesSubject.send(panelGitBranches) }
    }

    /// The workspace-level pull-request state shown in the sidebar (legacy
    /// `Workspace.pullRequest`).
    public var pullRequest: SidebarPullRequestState? {
        didSet { pullRequestSubject.send(pullRequest) }
    }

    /// Per-panel pull-request state keyed by panel id (legacy
    /// `Workspace.panelPullRequests`).
    public var panelPullRequests: [UUID: SidebarPullRequestState] = [:] {
        didSet { panelPullRequestsSubject.send(panelPullRequests) }
    }

    /// Per-panel directory display labels keyed by panel id, reported via
    /// `report_pwd <label> --path=<real-path>`. Display-only sidebar text:
    /// the File Explorer, Finder root, and git probing always use the real
    /// filesystem path owned by `Workspace.panelDirectories`.
    public var panelDirectoryDisplayLabels: [UUID: String] = [:] {
        didSet { panelDirectoryDisplayLabelsSubject.send(panelDirectoryDisplayLabels) }
    }

    @ObservationIgnored
    private let limitProvider: any SidebarLogEntryLimitProviding

    @ObservationIgnored
    private lazy var statusEntriesSubject = CurrentValueSubject<[String: SidebarStatusEntry], Never>(statusEntries)
    @ObservationIgnored
    private lazy var metadataBlocksSubject = CurrentValueSubject<[String: SidebarMetadataBlock], Never>(metadataBlocks)
    @ObservationIgnored
    private lazy var logEntriesSubject = CurrentValueSubject<[SidebarLogEntry], Never>(logEntries)
    @ObservationIgnored
    private lazy var progressSubject = CurrentValueSubject<SidebarProgressState?, Never>(progress)
    @ObservationIgnored
    private lazy var gitBranchSubject = CurrentValueSubject<SidebarGitBranchState?, Never>(gitBranch)
    @ObservationIgnored
    private lazy var panelGitBranchesSubject = CurrentValueSubject<[UUID: SidebarGitBranchState], Never>(panelGitBranches)
    @ObservationIgnored
    private lazy var pullRequestSubject = CurrentValueSubject<SidebarPullRequestState?, Never>(pullRequest)
    @ObservationIgnored
    private lazy var panelPullRequestsSubject = CurrentValueSubject<[UUID: SidebarPullRequestState], Never>(panelPullRequests)
    @ObservationIgnored
    private lazy var panelDirectoryDisplayLabelsSubject = CurrentValueSubject<[UUID: String], Never>(panelDirectoryDisplayLabels)

    /// Creates an empty sidebar-metadata model.
    /// - Parameter limitProvider: Supplies the configured maximum number of log
    ///   entries retained by ``appendLogEntry(message:level:source:)``. The app
    ///   target injects a `UserDefaults`-backed conformer; tests inject a fake.
    public init(limitProvider: any SidebarLogEntryLimitProviding) {
        self.limitProvider = limitProvider
    }

    /// Emits the current status entries on subscription, then on every change
    /// (replaces the legacy `Workspace status entries projection`).
    public var statusEntriesPublisher: AnyPublisher<[String: SidebarStatusEntry], Never> {
        statusEntriesSubject.eraseToAnyPublisher()
    }

    /// Emits the current metadata blocks on subscription, then on every change
    /// (replaces the legacy `Workspace metadata blocks projection`).
    public var metadataBlocksPublisher: AnyPublisher<[String: SidebarMetadataBlock], Never> {
        metadataBlocksSubject.eraseToAnyPublisher()
    }

    /// Emits the current log entries on subscription, then on every change
    /// (replaces the legacy `Workspace log entries projection`).
    public var logEntriesPublisher: AnyPublisher<[SidebarLogEntry], Never> {
        logEntriesSubject.eraseToAnyPublisher()
    }

    /// Emits the current progress state on subscription, then on every change
    /// (replaces the legacy `Workspace progress projection`).
    public var progressPublisher: AnyPublisher<SidebarProgressState?, Never> {
        progressSubject.eraseToAnyPublisher()
    }

    /// Emits the current workspace git-branch state on subscription, then on
    /// every change (replaces the legacy `Workspace git branch projection`).
    public var gitBranchPublisher: AnyPublisher<SidebarGitBranchState?, Never> {
        gitBranchSubject.eraseToAnyPublisher()
    }

    /// Emits the current per-panel git-branch states on subscription, then on
    /// every change (replaces the legacy `Workspace panel git branches projection`).
    public var panelGitBranchesPublisher: AnyPublisher<[UUID: SidebarGitBranchState], Never> {
        panelGitBranchesSubject.eraseToAnyPublisher()
    }

    /// Emits the current workspace pull-request state on subscription, then on
    /// every change (replaces the legacy `Workspace pull request projection`).
    public var pullRequestPublisher: AnyPublisher<SidebarPullRequestState?, Never> {
        pullRequestSubject.eraseToAnyPublisher()
    }

    /// Emits the current per-panel pull-request states on subscription, then on
    /// every change (replaces the legacy `Workspace panel pull requests projection`).
    public var panelPullRequestsPublisher: AnyPublisher<[UUID: SidebarPullRequestState], Never> {
        panelPullRequestsSubject.eraseToAnyPublisher()
    }

    /// Emits the current per-panel directory display labels on subscription,
    /// then on every change (feeds the sidebar observation pipeline so
    /// label-only `report_pwd` updates refresh sidebar rows without
    /// workspace-wide invalidation).
    public var panelDirectoryDisplayLabelsPublisher: AnyPublisher<[UUID: String], Never> {
        panelDirectoryDisplayLabelsSubject.eraseToAnyPublisher()
    }

    /// Emits a sidebar observation pulse without mutating metadata.
    ///
    /// The app target uses this when the rendered workspace-row snapshot changes
    /// because of workspace-owned fields that are not stored in this metadata
    /// model but intentionally share the same sidebar refresh pipeline.
    public func invalidateWorkspaceObservation() {
        statusEntriesSubject.send(statusEntries)
    }

    /// Upserts a sidebar status entry under its key (legacy
    /// `Workspace.statusEntries[entry.key] = entry`).
    /// - Parameter entry: The status entry to store; keyed by `entry.key`.
    public func addStatusEntry(_ entry: SidebarStatusEntry) {
        statusEntries[entry.key] = entry
    }

    /// Appends a sidebar log entry, trimming whitespace and dropping empty
    /// messages, then trims the buffer to the configured maximum (legacy
    /// `Workspace.appendSidebarLog(message:level:source:)`).
    ///
    /// The retention limit is read from the injected
    /// ``SidebarLogEntryLimitProviding`` (default 50 when unset) and clamped to
    /// the legacy `1...500` range, preserving the prior behavior exactly.
    /// - Parameters:
    ///   - message: The raw log message; whitespace-trimmed, ignored if empty.
    ///   - level: The severity level for the entry.
    ///   - source: An optional source label for the entry.
    public func appendLogEntry(message: String, level: SidebarLogLevel, source: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logEntries.append(SidebarLogEntry(message: trimmed, level: level, source: source, timestamp: Date()))
        let configuredLimit = limitProvider.configuredMaxSidebarLogEntries ?? 50
        let limit = max(1, min(500, configuredLimit))
        if logEntries.count > limit {
            logEntries.removeFirst(logEntries.count - limit)
        }
    }

    /// Sets or clears the sidebar progress indicator (legacy
    /// `Workspace.progress = …`).
    /// - Parameter progress: The new progress state, or `nil` to clear it.
    public func updateProgress(_ progress: SidebarProgressState?) {
        self.progress = progress
    }

    /// Sets or clears the workspace-level git-branch state (legacy
    /// `Workspace.gitBranch = …`).
    /// - Parameter gitBranch: The new git-branch state, or `nil` to clear it.
    public func updateGitBranch(_ gitBranch: SidebarGitBranchState?) {
        self.gitBranch = gitBranch
    }

    /// Sets or clears the workspace-level pull-request state (legacy
    /// `Workspace.pullRequest = …`).
    /// - Parameter pullRequest: The new pull-request state, or `nil` to clear.
    public func updatePullRequest(_ pullRequest: SidebarPullRequestState?) {
        self.pullRequest = pullRequest
    }

    /// Returns the metadata blocks sorted for sidebar display: descending
    /// priority, then descending timestamp, then ascending key (legacy
    /// `Workspace.sidebarMetadataBlocksInDisplayOrder()`).
    /// - Returns: The metadata blocks in stable display order.
    public func metadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        metadataBlocks.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }
}
