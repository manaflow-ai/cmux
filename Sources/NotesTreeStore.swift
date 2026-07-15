import CmuxFoundation
import Foundation
import Observation
import SwiftUI

/// Backing store for the Notes sidebar tab.
///
/// Owns the per-workspace notes tree as an eagerly-materialized hierarchy of
/// ``NotesTreeNode`` values (notes trees are small, so there is no lazy paging).
/// The filesystem is the source of truth; this store reflects it, watches it for
/// external changes (e.g. the `cmux-notes` skill writing files), and offers the
/// mutations the sidebar performs (new note/folder, move, session-folder sync).
///
/// All access happens on the main thread. Properties are not marked `@MainActor`
/// because `NSOutlineView` data-source/delegate methods call into the store on
/// the main thread without that annotation, matching ``FileExplorerStore``.
@Observable
final class NotesTreeStore {
    /// Top-level nodes (children of the workspace notes root).
    var rootNodes: [NotesTreeNode] = []
    /// Bumped on every structural reload so the outline view reloads its data.
    var contentRevision = 0
    /// Whether a local workspace is currently bound (false ⇒ empty/disabled tree).
    var hasWorkspace = false
    /// Abbreviated workspace path shown in the header bar — the same treatment
    /// as the Files tab's header (cwd with the home directory as `~`). Changes
    /// only when the bound cwd changes, which always reloads the tree.
    var headerDisplayPath = ""

    var projectRoot: String?
    var workspaceTitle: String = ""
    var cwd: String?
    /// The workspace's persistent note anchor — the identity the folder,
    /// flat-note filter, and session records are keyed by, so same-cwd
    /// workspaces never blend together.
    var workspaceAnchorId: String?
    /// Supplies the agent sessions currently known to run in this workspace's
    /// panes (live snapshots, the shared restorable-agent index, and the
    /// pane-TTY process pass). Injected by the composition root; starts on the
    /// main actor and may suspend for the process lookup.
    var observedSessionsProvider: (() async -> NotesTreeObservation)?
    /// Absolute path to `<projectRoot>/.cmux/notes/<workspace-folder>` (resolved,
    /// not necessarily created yet — materialized on first mutation/sync).
    var resolvedRootPath: String?
    /// Absolute path to `<projectRoot>/.cmux/notes` — the flat-note directory
    /// shared by the project, and the confinement boundary for tree mutations.
    var notesDirPath: String?
    /// Cap on session rows so a long-lived workspace doesn't flood the sidebar.
    let sessionRowLimit = 20
    /// Per-cwd live-session scan cap for the visible-sidebar refresh cadence.
    var liveSessionEntryLimit: Int { max(sessionRowLimit * 2, 30) }

    /// Paths the user has explicitly collapsed. Everything is expanded by
    /// default; only entries listed here stay collapsed across reloads.
    var collapsedPaths: Set<String> = []

    /// The workspace's live terminal panes from the latest observation pass.
    /// Each becomes a virtual folder row pointing back at its panel, with the
    /// pane's attached flat notes nested beneath it.
    var observedTerminals: [NotesTreeObservedTerminal] = []
    /// Agent sessions from the latest live pane observation. Workspace markers
    /// keep historical records for hydration/restore, but virtual session rows
    /// should only reflect sessions currently present in workspace panes.
    var observedSessionKeys: Set<String> = []
    /// Full live pane-session observations from the latest pass. `observedSessionKeys`
    /// is the persistence/display filter; this keeps the panel/anchor pointer
    /// needed to render a terminal row as its currently running agent.
    var observedSessions: [NotesTreeObservedSession] = []

    var watchers: [FileWatcher] = []
    var watcherTasks: [Task<Void, Never>] = []
    var watchedDirs: Set<String> = []
    /// Internal (not private) so tests can await the pending reload via
    /// `@testable import` without a production test hook.
    var reloadTask: Task<Void, Never>?
    var reloadGeneration = 0
    var reloadCoalesceTask: Task<Void, Never>?
    var markerRefreshTask: Task<Void, Never>?
    var visibilityRefreshTask: Task<Void, Never>?
    var emptyObservationRetryTask: Task<Void, Never>?
    var lastMarkerRefresh: Date?
    /// Rotation cursor for the bounded foreign-cwd live-session scans.
    var liveScanRotation = 0
    /// Floor between appear-triggered marker refreshes; Refresh bypasses it.
    let markerRefreshMinInterval: TimeInterval = 30
    /// Consecutive refresh passes that observed no pane sessions. The shared
    /// agent index loads asynchronously (seconds), so an early pass can see
    /// nothing; a few spaced retries keep the tab from sticking empty until
    /// the next appear.
    var emptyObservationRetries = 0
    let maxEmptyObservationRetries = 3

    let maxDepth = 12
    let nodeBudget = 5000
    let maxWatchers = 256
    /// Clock backing the coalesce/retry/poll waits below, so timed waits are
    /// cancellable and expressed via the injected-clock idiom rather than
    /// bare task sleeps.
    let clock = ContinuousClock()

    deinit {
        for task in watcherTasks { task.cancel() }
        reloadTask?.cancel()
        reloadCoalesceTask?.cancel()
        markerRefreshTask?.cancel()
        visibilityRefreshTask?.cancel()
        emptyObservationRetryTask?.cancel()
    }

}
