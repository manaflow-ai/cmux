import Combine
import CmuxSidebar
import CmuxSwiftRender
import Foundation

/// Memoized custom-sidebar data context plus the coalesced invalidation
/// stream that decides when the memo must be rebuilt.
///
/// Building the interpreter input walks every workspace's bonsplit tree, so
/// it must not run inside the 1 Hz `TimelineView` closure or on every
/// `tabManager.objectWillChange` (a workspace switch fires several). Instead:
///
/// - `invalidationPublisher(tabManager:sidebarUnread:workspaces:)` merges the
///   existing sidebar observation publishers (immediate fields, deep state,
///   pane-layout reorders, panel titles, focus broadcasts) with tab-manager
///   structure/selection/unread changes into one stream coalesced at
///   ``invalidationCoalesceInterval`` (leading edge synchronous). A view
///   subscribes once per workspace-id list, calls ``invalidate()`` and bumps
///   a `@State` revision when it fires, so a workspace switch costs at most
///   one leading + one trailing rebuild instead of one per `objectWillChange`.
/// - ``dataContext(now:buildInput:)`` rebuilds the expensive per-workspace
///   snapshots only after ``invalidate()``; every other call (the 1 Hz tick,
///   unrelated body re-evaluations) reuses them and only re-derives the cheap
///   `clock` value when the epoch second rolls over, so relative-time labels
///   still update. The emitted `[String: SwiftValue]` tree is value-equal
///   whenever the content is unchanged, which keeps
///   `SwiftRenderTrigger(sourceRevision, dataContext)` firing exactly when the
///   context content changes — no more often than the unmemoized build did.
///
/// This replaces `CustomSidebarPaneDataContextCache`, whose cache key
/// embedded the wall-clock second so every pane rebuilt the full context once
/// per second by design.
@MainActor
final class CustomSidebarDataContextStore {
    /// The interpreter input minus the wall clock: everything
    /// ``CustomSidebarDataContextBuilder`` needs except `now`.
    struct Input {
        var workspaces: [CustomSidebarWorkspaceSnapshot]
        var selectedWorkspaceId: UUID?
        var selectedWorkspaceTitle: String
        var totalUnreadCount: Int
    }

    /// Cross-source coalescing for the merged invalidation stream, matching
    /// the extension sidebar's observation interval.
    static let invalidationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)

    /// Per-workspace panel-title streams coalesce harder before joining the
    /// merged stream: agent TUIs can animate their terminal title at ~10 Hz,
    /// and re-interpreting the sidebar at that rate is the churn class the
    /// settled title-observation models exist to avoid. An isolated title
    /// change still lands on the synchronous leading edge.
    static let panelTitleCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(500)

    private var cachedInput: Input?
    private var cachedContext: [String: SwiftValue]?
    private var cachedContextEpochSecond: Int?

    /// Drops the memoized workspace snapshots. The next ``dataContext(now:buildInput:)``
    /// call rebuilds them through `buildInput`.
    func invalidate() {
        cachedInput = nil
    }

    /// Returns the interpreter data context for `now`, rebuilding the
    /// workspace snapshots only when invalidated and re-deriving the context
    /// dictionary only when the snapshots were rebuilt or the epoch second
    /// changed.
    func dataContext(
        now: Date,
        buildInput: () -> Input
    ) -> [String: SwiftValue] {
        let epochSecond = Int(now.timeIntervalSince1970)
        if let cachedInput, let cachedContext, cachedContextEpochSecond == epochSecond {
            return cachedContext
        }
        let input = cachedInput ?? buildInput()
        let context = CustomSidebarDataContextBuilder().dataContext(
            for: CustomSidebarContextSnapshot(
                workspaces: input.workspaces,
                selectedWorkspaceId: input.selectedWorkspaceId,
                selectedWorkspaceTitle: input.selectedWorkspaceTitle,
                totalUnreadCount: input.totalUnreadCount,
                now: now
            )
        )
        cachedInput = input
        cachedContext = context
        cachedContextEpochSecond = epochSecond
        return context
    }

    /// Projects the live tab-manager state into the interpreter input. Runs
    /// the per-workspace bonsplit tree walks; call only after an invalidation.
    static func input(tabManager: TabManager, sidebarUnread: SidebarUnreadModel) -> Input {
        let selectedId = tabManager.selectedTabId
        let workspaces = tabManager.tabs.enumerated().map { index, workspace in
            workspace.customSidebarWorkspaceSnapshot(
                index: index,
                selectedId: selectedId,
                unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id)
            )
        }
        let selectedWorkspace = tabManager.tabs.first { $0.id == selectedId }
        return Input(
            workspaces: workspaces,
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? "",
            totalUnreadCount: sidebarUnread.totalUnreadCount
        )
    }

    /// Merged, coalesced invalidation stream for one set of workspaces.
    ///
    /// Memoize the publisher in `@State` and rebuild it only when the
    /// workspace id list changes: rebuilding inline each body pass
    /// re-subscribes `.onReceive` to a fresh publisher every render, replaying
    /// the current state and re-invalidating in a loop (issue #5970).
    ///
    /// Sources:
    /// - `tabManager.objectWillChange`: workspace structure, selection, and
    ///   window-title/unread side effects — the same signals that used to
    ///   force a rebuild per emission, now coalesced.
    /// - `sidebarUnread.objectWillChange`: badge counts (equality-guarded
    ///   upstream, so notification churn that changes no badge never fires).
    /// - Per workspace: the curated immediate/deep observation publishers,
    ///   `paneLayoutVersionPublisher` (pure panel reorders), and a
    ///   harder-coalesced `$panelTitles` (surface titles).
    /// - `.ghosttyDidFocusSurface`: focused-panel changes (already deferred
    ///   and coalesced by `FocusSurfaceBroadcaster`).
    ///
    /// Automatic process-title churn is deliberately not in this stream; it
    /// reaches the view through the settled
    /// `sidebarProcessTitleObservations` models, mirroring the default and
    /// extension sidebars.
    static func invalidationPublisher(
        tabManager: TabManager,
        sidebarUnread: SidebarUnreadModel,
        workspaces: [Workspace]
    ) -> AnyPublisher<Void, Never> {
        let workspaceStreams = workspaces.map { workspace in
            Publishers.Merge4(
                workspace.sidebarImmediateObservationPublisher,
                workspace.sidebarObservationPublisher,
                workspace.paneLayoutVersionPublisher
                    .removeDuplicates()
                    .map { _ in () }
                    .eraseToAnyPublisher(),
                workspace.$panelTitles
                    .removeDuplicates()
                    .map { _ in () }
                    .coalesceLatest(
                        for: panelTitleCoalesceInterval,
                        scheduler: RunLoop.main
                    )
            )
            .map { _ in () }
            .eraseToAnyPublisher()
        }
        let focusStream = NotificationCenter.default
            .publisher(for: .ghosttyDidFocusSurface)
            .map { _ in () }
            .eraseToAnyPublisher()
        return Publishers.MergeMany(
            [tabManager.objectWillChange.eraseToAnyPublisher(),
             sidebarUnread.objectWillChange.eraseToAnyPublisher(),
             focusStream]
                + workspaceStreams
        )
        .receive(on: RunLoop.main)
        .coalesceLatest(
            for: invalidationCoalesceInterval,
            scheduler: RunLoop.main
        )
        .eraseToAnyPublisher()
    }
}
