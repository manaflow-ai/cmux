import CmuxNextCompat
public import CmuxNextDaemon
import Foundation
public import Observation
import os

/// The one owner of what happens to a workspace with no pane.
///
/// A workspace whose last tab closed (Cmd-W, the tab's x, the CLI, or the
/// process exiting) closes: this connection saw it with a pane, then without
/// one (dogfood nxdog9, REWRITE.md round 3). The window rule then closes a
/// window that held only that workspace (`WindowRegistry`).
///
/// A workspace that has never held a pane stays empty so the app can show its
/// new-workspace actions. A workspace that was populated and loses its last
/// terminal is repaired after checking the terminal registry. What was seen
/// counts across connection epochs so a daemon restart still recovers a host
/// that died, while a genuinely new empty workspace remains available for
/// the empty-state UI.
///
/// Two paths create a workspace's first terminal: this app populating a
/// workspace it just created (create-workspace, then create-terminal), and
/// the repair. Both answer before their pane delta reaches the mirror, and
/// meanwhile the workspace still looks empty. Each workspace therefore has a
/// `FirstTerminal` state here from the moment either path starts until the
/// store reports the workspace populated, and a workspace with a state is
/// never repaired or closed. A failed request releases it; the next store
/// change retries.
///
/// Process-wide per daemon, so two windows showing the same workspace send
/// one command, and a workspace no window shows closes too.
///
/// Observable through `states` (`isSettling`): a window shows nothing,
/// rather than the new-workspace actions, while its workspace is settling.
/// A failed first terminal is kept in `failures` and shown with a retry,
/// not refilled by itself on that connection (cx-tzlqb).
@MainActor @Observable
public final class EmptyWorkspaceRepair {
    /// Who is giving a workspace its first terminal.
    public enum FirstTerminal: Equatable {
        /// This app is running create-workspace + create-terminal
        /// (`populating`); the count of nested callers.
        case populating(Int)
        /// A create-terminal was sent (a repair) or answered (either path);
        /// waiting for the store to show a pane.
        case awaitingPane
        /// This app is moving every tab out of the workspace and closes it
        /// afterwards (a tab drag), or its last tab closed and it is being
        /// closed: it is empty on purpose, never repaired.
        case closing
    }

    /// Creates the first terminal of `key` (`create-terminal`, which adds the
    /// first screen and pane). Returns the new surface. Tests replace it.
    @ObservationIgnored public var create: @MainActor (WorkspaceKey) async throws -> SurfaceID?
    /// Closes `key`, a workspace whose last tab closed. Tests replace it.
    @ObservationIgnored public var close: @MainActor (WorkspaceKey) async throws -> Void = { _ in }
    /// Why `key` lost its last pane. Tests replace it.
    @ObservationIgnored public var cause: @MainActor (WorkspaceKey) async -> EmptiedWorkspaceCause
    /// Whether commands can run now. Tests replace it.
    @ObservationIgnored public var canCreate: @MainActor () -> Bool
    public private(set) var states: [WorkspaceKey: FirstTerminal] = [:]
    /// Why a workspace's first terminal failed, until a pane shows or New.
    private(set) var failures: [WorkspaceKey: String] = [:]
    /// Each failure's connection epoch: a reconnect lifts the refill hold.
    @ObservationIgnored private var failureEpochs: [WorkspaceKey: Int] = [:]
    /// Created workspaces whose terminal and then close failed: released.
    @ObservationIgnored private var keptAfterFailedClose: Set<WorkspaceKey> = []
    /// The last emptied workspaces and what this app did with each (closed,
    /// or kept with a new terminal), newest last, for `debug.windows`: a
    /// workspace that disappears is always explained.
    @ObservationIgnored public private(set) var decisions: [(key: WorkspaceKey, cause: EmptiedWorkspaceCause)] = []
    /// Workspaces seen with a pane, with the connection epoch they were seen
    /// on: one seen on the current connection that has no pane now had its
    /// last tab closed.
    @ObservationIgnored private var populated: [WorkspaceKey: Int] = [:]
    /// Workspaces that have ever held a pane in this daemon session. This is
    /// separate from `populated`: the latter identifies a last-tab close on
    /// the current connection, while this set lets a reconnect distinguish a
    /// lost terminal from a workspace created empty for the new-tab flow.
    @ObservationIgnored private var everPopulated: Set<WorkspaceKey> = []
    /// The daemon store's connection epoch. Tests replace it.
    /// Explicit New may create the chat page; crash recovery still creates a terminal.
    @ObservationIgnored public var createFirst: (@MainActor (WorkspaceKey) async throws -> SurfaceID?)?

    @ObservationIgnored public var epoch: @MainActor () -> Int
    /// Whether the store holds a live snapshot. The launch snapshot's
    /// provisional tree was not seen on any connection, so a workspace it
    /// shows with a pane must not count as emptied when the live tree shows
    /// it without one (the daemon restarted without its terminals): that one
    /// is repaired. Tests replace it.
    @ObservationIgnored public var isLive: @MainActor () -> Bool
    @ObservationIgnored private var observation: Task<Void, Never>?
    /// The store observed; weak, the store owns its life.
    @ObservationIgnored private weak var store: DaemonStore?
    /// One pane observation per workspace in the store (`watch`).
    @ObservationIgnored private var watchers: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The live tree epoch whose workspaces were all examined.
    @ObservationIgnored private var checkedTreeEpoch: Int??
    /// Whether each watched workspace had a pane when last examined.
    @ObservationIgnored private var seenPane: [ObjectIdentifier: Bool] = [:]
    /// Emptied workspaces to examine again on the next change (`retryPending`).
    @ObservationIgnored private var retries: Set<WorkspaceKey> = []
    /// Workspaces examined for a missing pane since launch: a store change
    /// that touches none of them must examine none (sidebar churn).
    @ObservationIgnored private(set) var visited = 0
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.empty-workspace")

    /// The daemon-facing closures come from the App (`init(daemon:)`), which
    /// owns the connection and the workspace close path.
    public init(store: DaemonStore,
                create: @escaping @MainActor (WorkspaceKey) async throws -> SurfaceID?,
                close: @escaping @MainActor (WorkspaceKey) async throws -> Void,
                cause: @escaping @MainActor (WorkspaceKey) async -> EmptiedWorkspaceCause,
                canCreate: @escaping @MainActor () -> Bool,
                epoch: @escaping @MainActor () -> Int,
                isLive: @escaping @MainActor () -> Bool) {
        self.create = create
        self.close = close
        self.cause = cause
        self.canCreate = canCreate
        self.epoch = epoch
        self.isLive = isLive
        observe(store)
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
            for task in watchers.values { task.cancel() }
        }
    }

    /// One observation per workspace of whether it has a pane, which wakes
    /// only when that workspace gains its first pane or loses its last, plus
    /// one store observation of membership and of the connection's first live
    /// tree. A move, a group change or a change to another workspace wakes
    /// nothing here (sidebar churn: this looked at every workspace on each).
    private func observe(_ store: DaemonStore) {
        self.store = store
        observation = Task { [weak self, weak store] in
            for await _ in ObservationStream({ () -> [String] in
                guard let store else { return [] }
                // Turning live counts as a change: a tree drawn from the
                // launch snapshot is first seen on a connection then.
                return [String(store.isLoaded), String(store.isProvisional), String(store.workspaceSetRevision),
                        store.liveTreeEpoch.map(String.init) ?? "-"]
            }) {
                guard let self, let store else { return }
                self.membershipDidChange(store)
            }
        }
    }

    /// Watches the workspaces that joined, stops watching the ones that left,
    /// and forgets what it held for those. On a connection's first live tree
    /// it examines every workspace once: what was seen with a pane on the old
    /// connection counts again only if the new one shows it with a pane.
    /// O(workspaces) only on a membership change or a new connection.
    private func membershipDidChange(_ store: DaemonStore) {
        let current = store.workspaces
        let everyOne = isLive() && checkedTreeEpoch != store.liveTreeEpoch
        if everyOne { checkedTreeEpoch = store.liveTreeEpoch }
        var live = Set<ObjectIdentifier>()
        live.reserveCapacity(current.count)
        for workspace in current {
            let id = ObjectIdentifier(workspace)
            live.insert(id)
            let joined = watchers[id] == nil
            if joined { watchers[id] = watch(workspace) }
            if joined || everyOne { workspaceDidChange(workspace) }
        }
        for (id, task) in watchers where !live.contains(id) {
            task.cancel()
            watchers[id] = nil
            seenPane[id] = nil
        }
        let present = Set(current.compactMap(\.key))
        populated = populated.filter { present.contains($0.key) }
        for key in states.keys where !present.contains(key) && states[key] == .closing { states[key] = nil }
        for key in failures.keys where !present.contains(key) { clearFailure(key) }
        keptAfterFailedClose.formIntersection(present)
        retries.formIntersection(present)
        retryPending()
    }

    /// Follows whether `workspace` has a pane; wakes only when that flips.
    private func watch(_ workspace: WorkspaceModel) -> Task<Void, Never> {
        // task-owner: one per watched workspace in `watchers`, cancelled when it leaves the store or the repair goes
        Task { [weak self, weak workspace] in
            for await hasPane in ObservationStream({ workspace.map(Self.hasPane) ?? false }) {
                guard let self, let workspace else { return }
                // The membership pass examined it when it joined; only a flip since counts.
                guard self.seenPane[ObjectIdentifier(workspace)] != hasPane else { continue }
                self.workspaceDidChange(workspace)
                self.retryPending()
            }
        }
    }

    /// `workspace` gained its first pane or lost its last.
    private func workspaceDidChange(_ workspace: WorkspaceModel) {
        visited += 1
        let hasPane = Self.hasPane(workspace)
        seenPane[ObjectIdentifier(workspace)] = hasPane
        guard let key = workspace.key else { return }
        // The launch snapshot can contain a pane before the live tree arrives.
        // Remember that evidence, but do not close or repair anything until
        // the daemon has supplied a live snapshot.
        if hasPane { everPopulated.insert(key) }
        guard isLive(), !Self.isHome(workspace) else { return }
        if hasPane {
            notePopulated(key)
        } else {
            closeIfEmptied(key)
        }
    }

    /// Emptied workspaces whose close could not start (no connection to
    /// send it on): examined again on the next change this repair sees
    /// (O(retries), never every workspace).
    private func retryPending() {
        guard !retries.isEmpty, let store else { return }
        let pending = retries
        retries.removeAll()
        for key in pending {
            guard let workspace = store.workspace(id: key.rawValue), workspace.key == key else { continue }
            workspaceDidChange(workspace)
        }
    }

    /// The store's home workspace (workspace-kind-v1) starts empty on
    /// purpose and the daemon never closes it: HomeService owns its content
    /// (the Chief conversation tab), so it is neither repaired nor closed.
    private static func isHome(_ workspace: WorkspaceModel) -> Bool {
        workspace.kind == "home"
    }

    private static func hasPane(_ workspace: WorkspaceModel) -> Bool {
        !workspace.screens.allSatisfy(\.panes.isEmpty)
    }

    private func notePopulated(_ key: WorkspaceKey) {
        populated[key] = epoch()
        if failures[key] != nil { clearFailure(key) }
        // Whoever created the terminal is done, unless this app is still
        // inside its own populate call or closing it.
        if states[key] == .awaitingPane { states[key] = nil }
    }

    /// Closes `key` when this connection saw it with a pane and nothing
    /// else owns it. Returns whether `key` is (being) closed.
    @discardableResult
    private func closeIfEmptied(_ key: WorkspaceKey) -> Bool {
        guard populated[key] == epoch(), states[key] == nil else { return states[key] == .closing }
        // Disconnected: the next change this repair sees tries again.
        guard canCreate() else { retries.insert(key); return false }
        states[key] = .closing
        populated[key] = nil
        let close = close, cause = cause, create = create
        // task-owner: one decision per emptied workspace; the claim is the state above
        Task {
            // A lost terminal (its host died: crash, kill, reboot) is not a
            // closed tab: the workspace stays and gets a new terminal.
            if await cause(key) == .terminalLost {
                guard states[key] == .closing else { return }
                states[key] = .awaitingPane
                record(key, .terminalLost)
                logger.info("workspace \(key.rawValue, privacy: .public) lost its last terminal; keeping it with a new terminal")
                do {
                    _ = try await create(key)
                } catch {
                    if states[key] == .awaitingPane { states[key] = nil; recordFailure(key, error) }
                    logger.error("refilling a workspace with a lost terminal failed: \(String(describing: error), privacy: .public)")
                }
                return
            }
            record(key, .tabClosed)
            logger.info("workspace \(key.rawValue, privacy: .public) lost its last tab; closing it")
            do {
                try await close(key)
            } catch {
                // Still open and empty: the next change repairs it instead.
                if states[key] == .closing { states[key] = nil }
                logger.error("closing emptied workspace failed: \(String(describing: error), privacy: .public)")
            }
        }
        return true
    }

    private func record(_ key: WorkspaceKey, _ cause: EmptiedWorkspaceCause) {
        decisions.append((key, cause))
        if decisions.count > 32 { decisions.removeFirst(decisions.count - 32) }
    }

    /// Checks `workspace` after a store change. A populated workspace whose
    /// last tab closed is closed; a previously populated workspace whose host
    /// died is refilled. A genuinely new empty workspace is left alone for
    /// `WorkspaceContentController` to render its actions.
    public func check(_ workspace: WorkspaceModel, created: @escaping @MainActor (SurfaceID) -> Void) {
        guard let key = workspace.key, isLive(), !Self.isHome(workspace) else { return }
        guard !Self.hasPane(workspace) else { return notePopulated(key) }
        if let failed = failureEpochs[key], failed != epoch() { clearFailure(key) }
        guard states[key] == nil, !closeIfEmptied(key), everPopulated.contains(key), failures[key] == nil else { return }
        createTab(key, create: create, created: created)
    }

    /// Creates the first tab after an explicit New action.
    /// The state claim makes repeated key presses idempotent while the daemon
    /// delta is still in flight.
    public func createFirstTab(_ key: WorkspaceKey, created: @escaping @MainActor (SurfaceID) -> Void = { _ in }) {
        guard states[key] == nil, canCreate() else { return }
        clearFailure(key)
        createTab(key, create: createFirst ?? create, created: created)
    }

    private func createTab(_ key: WorkspaceKey, create: @escaping @MainActor (WorkspaceKey) async throws -> SurfaceID?,
                           created: @escaping @MainActor (SurfaceID) -> Void) {
        guard states[key] == nil, canCreate() else { return }
        states[key] = .awaitingPane
        logger.info("workspace \(key.rawValue, privacy: .public) requested a new tab")
        Task {
            do {
                if let surface = try await create(key) { created(surface) }
            } catch {
                if states[key] == .awaitingPane { states[key] = nil; recordFailure(key, error) }
                logger.error("creating a terminal for an empty workspace failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Whether `key` is about to change by itself: its first terminal is on
    /// its way (this app's create, or a repair) or it is being closed. An
    /// empty workspace that is settling is not waiting for the user.
    public func isSettling(_ key: WorkspaceKey) -> Bool { states[key] != nil }

    /// Why `key`'s first terminal did not start, while it is still empty.
    public func failure(_ key: WorkspaceKey) -> String? { failures[key] }

    /// `key` is emptied on purpose (its tabs are moving to another
    /// workspace) and will close: no repair until `endClosing`.
    public func beginClosing(_ key: WorkspaceKey) { states[key] = .closing }

    /// The move failed (the tabs stayed): repairs apply again.
    public func endClosing(_ key: WorkspaceKey) {
        if states[key] == .closing { states[key] = nil }
    }

    /// A person's first tab in an existing empty workspace (Cmd-T): a failure
    /// releases it with its reason; `populating` would leave it `.closing`
    /// (blank, every later Cmd-T dropped, cx-tzlqb).
    public func fillFirstTab<T>(_ key: WorkspaceKey, _ body: () async throws -> T) async throws -> T {
        states[key] = .awaitingPane
        clearFailure(key)
        do {
            return try await body()
        } catch {
            if states[key] == .awaitingPane { states[key] = nil; recordFailure(key, error) }
            throw error
        }
    }

    /// Marks `key` as being populated by this app for the duration of
    /// `body` (create-workspace then create-terminal). On success the
    /// workspace stays owned until the store shows its pane, because
    /// `body` returns with the create-terminal reply, before the delta. On
    /// failure the workspace is never repaired (its creator closes it).
    public func populating<T>(_ key: WorkspaceKey, _ body: () async throws -> T) async rethrows -> T {
        if case .populating(let count) = states[key] { states[key] = .populating(count + 1) } else { states[key] = .populating(1) }
        do {
            let value = try await body()
            finishPopulating(key, succeeded: true)
            return value
        } catch {
            finishPopulating(key, succeeded: false, error: error)
            throw error
        }
    }

    /// `WorkspaceCreation` could not close `key` after its terminal failed.
    public func closeFailed(_ key: WorkspaceKey) { keptAfterFailedClose.insert(key) }

    private func recordFailure(_ key: WorkspaceKey, _ error: Error) {
        failures[key] = String(describing: error)
        failureEpochs[key] = epoch()
    }

    private func clearFailure(_ key: WorkspaceKey) {
        failures[key] = nil
        failureEpochs[key] = nil
    }

    private func finishPopulating(_ key: WorkspaceKey, succeeded: Bool, error: Error? = nil) {
        guard case .populating(let count) = states[key] else { return }
        if count > 1 {
            states[key] = .populating(count - 1)
        } else if !succeeded, keptAfterFailedClose.remove(key) != nil {
            states[key] = nil
            if let error { recordFailure(key, error) }
        } else {
            // A failed create was closed again by its creator
            // (`WorkspaceCreation`): it is empty on purpose and never
            // repaired. The state goes when the workspace is gone.
            states[key] = succeeded ? .awaitingPane : .closing
        }
    }
}
