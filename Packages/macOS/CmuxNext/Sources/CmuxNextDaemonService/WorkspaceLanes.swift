public import CmuxNextActions
public import CmuxNextDaemon

/// One window's workspace creates and closes run one at a time, in the order
/// they were asked for (cx-7cit9). Cmd-N at key-repeat speed used to start
/// every create at once: the daemon numbered them in whatever order the
/// requests arrived, and a Cmd-Shift-W pressed before its workspace was
/// reported closed the workspace the window still showed. In a lane, each
/// create gets the next number, and a close lands after the creates pressed
/// before it.
///
/// A create is outstanding from the press until the daemon has created it
/// and the store lists it. A close pressed meanwhile takes the newest
/// outstanding create, by its exact key: one not started yet never runs;
/// one in flight closes once the daemon has made it.
@MainActor
public final class WorkspaceLanes {
    public static let shared = WorkspaceLanes()

    public init() {}

    @MainActor
    private final class Create {
        let key: String
        let close: @MainActor (String) async -> Void
        var started = false
        var cancelled = false
        var closeWhenCreated = false
        var created = false
        /// True once the store has applied the daemon's events up to the create's
        /// reply: the workspace is listed then, or was closed again since.
        var settled: @MainActor () -> Bool = { false }

        init(key: String, close: @escaping @MainActor (String) async -> Void) {
            self.key = key
            self.close = close
        }
    }

    /// Each window's last queued operation (the lane `""` holds creates no
    /// window claimed).
    private var tails: [String: Task<Void, Never>] = [:]
    /// Each window's outstanding creates, oldest first.
    private var creates: [String: [Create]] = [:]

    /// Runs `body`, which creates workspace `key` and returns its id, after
    /// the window's earlier operations. `close` closes it by key (a close
    /// pressed while it was in flight). Throws `CancellationError` when a
    /// close took it before it started. `settle`, after `body`, returns the check
    /// that the store has caught up with the create (`WorkspaceSpawner.settled`); it
    /// never waits for that, so the next create starts at once.
    public func create(_ key: WorkspaceKey, window: String?, close: @escaping @MainActor (String) async -> Void,
                       settle: @escaping @MainActor () async -> @MainActor () -> Bool,
                       _ body: @escaping @MainActor () async throws -> String) async throws -> String {
        let lane = window ?? ""
        let entry = Create(key: key.rawValue, close: close)
        creates[lane, default: []].append(entry)
        let task = enqueue(lane) { [weak self] () async throws -> String in
            if entry.cancelled { throw CancellationError() }
            entry.started = true
            do {
                let id = try await body()
                entry.settled = await settle()
                entry.created = true
                if entry.closeWhenCreated {
                    self?.drop(entry, from: lane)
                    await entry.close(id)
                }
                return id
            } catch {
                self?.drop(entry, from: lane)
                throw error
            }
        }
        return try await task.value
    }

    /// Runs `body` after the window's earlier operations (a close of a
    /// workspace the window shows); the task ends when it has.
    @discardableResult
    public func run(in window: String?, _ body: @escaping @MainActor () async -> ActionWorkFailure?) -> ActionWork {
        let task = enqueue(window ?? "") { await body() }
        return Task { (try? await task.value) ?? nil }
    }

    /// A close pressed in `window`: takes its newest outstanding create, if
    /// any (`listed` says whether the store lists a workspace; `taken` gets its
    /// key, whose pending row goes). True when it did, so the caller must not
    /// also close the shown workspace.
    public func closeNewestCreate(in window: String, listed: (String) -> Bool, taken: (String) -> Void = { _ in }) -> Bool {
        prune(window, listed: listed)
        guard let newest = creates[window]?.last(where: { !$0.closeWhenCreated }) else { return false }
        taken(newest.key)
        if !newest.started {
            drop(newest, from: window)
            newest.cancelled = true
        } else if !newest.created {
            newest.closeWhenCreated = true
        } else {
            drop(newest, from: window)
            let key = newest.key
            run(in: window) { await newest.close(key); return nil }
        }
        return true
    }

    /// Forgets the creates the store now lists, or has caught up with: the
    /// window shows them, so a close takes them as the shown workspace. One
    /// closed another way (its row's close button, the CLI) before any prune
    /// saw it listed is settled too, so a later Cmd-Shift-W never takes it
    /// and closes nothing.
    public func prune(_ lane: String, listed: (String) -> Bool) {
        creates[lane]?.removeAll { $0.created && (listed($0.key) || $0.settled()) }
        if creates[lane]?.isEmpty == true { creates[lane] = nil }
    }

    /// How many creates `window` has outstanding (tests and diagnostics).
    public func outstandingCreates(in window: String) -> Int {
        creates[window]?.count ?? 0
    }

    private func drop(_ entry: Create, from lane: String) {
        creates[lane]?.removeAll { $0 === entry }
        if creates[lane]?.isEmpty == true { creates[lane] = nil }
    }

    private func enqueue<T>(_ lane: String, _ body: @escaping @MainActor () async throws -> T) -> Task<T, Error> {
        let previous = tails[lane]
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await body()
        }
        tails[lane] = Task { _ = try? await task.value }
        return task
    }
}
