public import AppKit
public import CmuxNextCompat
public import UniformTypeIdentifiers

/// One Launch Services or icon question ``WorkspaceQueries`` answers and keeps: its key, whether a kept answer goes
/// stale (an app installed or removed since changes it; an icon does not), and the blocking query that answers it.
public nonisolated struct WorkspaceQuery<Value: Sendable>: Sendable {
    let key: WorkspaceQueryKey
    let refreshes: Bool
    let ask: @Sendable (any WorkspaceQuerying) -> Value
}

extension WorkspaceQuery {
    /// A question of the caller's own whose blocking `ask` combines system answers, such as an Open With list with
    /// each app's name. `id` names it: one id, one question and one answer type.
    public init(id: String, refreshes: Bool, ask: @escaping @Sendable (any WorkspaceQuerying) -> Value) {
        self.init(key: .custom(id), refreshes: refreshes, ask: ask)
    }
}

/// What a ``WorkspaceQuery`` asks; a question and its answer type correspond one to one.
nonisolated enum WorkspaceQueryKey: Hashable, Sendable {
    case application(bundleIdentifier: String)
    case defaultApplicationForURL(URL)
    case defaultApplicationForType(UTType)
    case applicationsForURL(URL)
    case applicationsForType(UTType)
    case iconForFile(path: String, side: CGFloat?)
    case iconForType(UTType, side: CGFloat?)
    case custom(String)
}

extension WorkspaceQuery where Value == URL? {
    /// The app with `bundleIdentifier`; nil when none is installed.
    public static func application(withBundleIdentifier bundleIdentifier: String) -> Self {
        Self(key: .application(bundleIdentifier: bundleIdentifier), refreshes: true) {
            $0.application(withBundleIdentifier: bundleIdentifier)
        }
    }

    /// The default app for `url`: a file's own (Get Info can name one per document), else by its scheme.
    public static func defaultApplication(toOpen url: URL) -> Self {
        Self(key: .defaultApplicationForURL(url), refreshes: true) { $0.defaultApplication(toOpen: url) }
    }

    /// The default app for content of `type`.
    public static func defaultApplication(toOpen type: UTType) -> Self {
        Self(key: .defaultApplicationForType(type), refreshes: true) { $0.defaultApplication(toOpen: type) }
    }
}

extension WorkspaceQuery where Value == [URL] {
    /// Every app that opens `url`, in Launch Services' order.
    public static func applications(toOpen url: URL) -> Self {
        Self(key: .applicationsForURL(url), refreshes: true) { $0.applications(toOpen: url) }
    }

    /// Every app that opens content of `type`, in Launch Services' order.
    public static func applications(toOpen type: UTType) -> Self {
        Self(key: .applicationsForType(type), refreshes: true) { $0.applications(toOpen: type) }
    }
}

extension WorkspaceQuery where Value == NSImage {
    /// The icon of the file or app at `path`, `side` points square; nil `side` keeps the icon's own size. Each size
    /// is its own image, so no reader resizes an image another one shows (a reader that resizes copies it first).
    public static func fileIcon(atPath path: String, side: CGFloat? = nil) -> Self {
        Self(key: .iconForFile(path: path, side: side), refreshes: false) { system in
            Self.sized(system.fileIcon(atPath: path), side)
        }
    }

    /// The icon of `type`, `side` points square; nil `side` keeps the icon's own size.
    public static func typeIcon(_ type: UTType, side: CGFloat? = nil) -> Self {
        Self(key: .iconForType(type, side: side), refreshes: false) { system in
            Self.sized(system.typeIcon(type), side)
        }
    }

    private static func sized(_ icon: NSImage, _ side: CGFloat?) -> NSImage {
        if let side { icon.size = NSSize(width: side, height: side) }
        return icon
    }
}

// memory: bounded: at most `capacity` answers (256 by default), the least recently read dropped first; an answer is
// one app URL, at most a few dozen app URLs, or one icon image at one size.
/// The app's Launch Services and icon answers: which app opens a link, a file or a type, where an app is, and the
/// icon of a file, an app or a type. Each question is asked on the system lane of ``BackgroundWork`` through the
/// checked seams (``WorkspaceQuerying``), never on the main thread, and its answer is kept in a bounded
/// least-recently-used table on the main actor. A menu or a list reads kept answers synchronously
/// (``cached(_:)``), asks for the missing ones with a reply (``value(_:priority:then:)``) or an await
/// (``value(_:priority:)``), and warms the rows it is about to show (``prefetch(_:priority:)``).
///
/// This is Chrome's `IconManager` (chrome/browser/icon_manager.cc): a per-process icon cache on the UI thread whose
/// misses an `IconLoader` fills on a `MayBlock` thread pool sequence and replies to the UI thread. As there, one
/// question in flight serves every caller that asks it meanwhile.
///
/// An app answer goes stale: once a read finds it older than `refreshAfter`, the kept answer is served and asked
/// again at best effort, so an app installed since shows one read later. Icons do not go stale.
///
/// ```swift
/// queries.value(WorkspaceQuery<[URL]>.applications(toOpen: type), priority: .userBlocking) { apps in fill(apps) }
/// let editor = try? await queries.value(WorkspaceQuery<URL?>.defaultApplication(toOpen: .sourceCode), priority: .userBlocking)
/// queries.prefetch(visibleRows.map { WorkspaceQuery<NSImage>.fileIcon(atPath: $0.path, side: 16) })
/// ```
@MainActor
public final class WorkspaceQueries {
    /// A kept answer: the value boxed with its type, when it was asked, and when it was last read.
    private struct Entry {
        var value: any Sendable
        var asked: ContinuousClock.Instant
        var used: UInt64
    }

    /// An answer boxed with its type, so a kept nil (no app) reads back as an answer and not as a miss.
    private struct Stored<Value: Sendable>: Sendable {
        let value: Value
    }

    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    private let system: any WorkspaceQuerying
    private let capacity: Int
    private let refreshAfter: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private let owner: MainTaskOwner
    private var entries: [WorkspaceQueryKey: Entry] = [:]
    /// The questions on the lane, each with the replies waiting for its answer.
    private var asking: [WorkspaceQueryKey: [@MainActor (any Sendable) -> Void]] = [:]
    private var reads: UInt64 = 0

    /// - Parameters:
    ///   - work: The app's lanes; questions run on its system lane.
    ///   - mainWork: The main-thread scheduler that answers come back on (class `visible`).
    ///   - system: The blocking queries (tests pass a fake).
    ///   - capacity: The most answers kept (at least 1).
    ///   - refreshAfter: How old an app answer may be before a read asks again.
    ///   - now: The clock reads use (tests pass a manual one).
    public init(work: BackgroundWork, mainWork: MainWorkScheduler, system: any WorkspaceQuerying = SystemWorkspaceQuerying(),
                capacity: Int = 256, refreshAfter: Duration = .seconds(60),
                now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.work = work
        self.mainWork = mainWork
        self.system = system
        self.capacity = max(1, capacity)
        self.refreshAfter = refreshAfter
        self.now = now
        owner = mainWork.board.owner("workspace.queries")
    }

    /// The number of kept answers.
    public var count: Int { entries.count }

    /// The kept answer to `query`, or nil when it was not asked yet (or was dropped). A stale app answer is
    /// returned and asked again in the background.
    public func cached<Value>(_ query: WorkspaceQuery<Value>) -> Value? {
        guard var entry = entries[query.key], let stored = entry.value as? Stored<Value> else { return nil }
        reads += 1
        entry.used = reads
        entries[query.key] = entry
        if query.refreshes, now() - entry.asked >= refreshAfter { ask(query, at: .bestEffort) }
        return stored.value
    }

    /// Calls `then` with the answer to `query`: in this turn when it is kept, else on main once the system lane
    /// answers (posted in class `visible` for `owner`'s screen update). A question already on the lane is not
    /// asked twice.
    ///
    /// - Parameters:
    ///   - query: The question.
    ///   - priority: How much a person waits for it: `userBlocking` for a menu that is open, `userVisible` for
    ///     rows on screen.
    ///   - then: Gets the answer on the main actor.
    public func value<Value>(_ query: WorkspaceQuery<Value>, priority: WorkPriority = .userVisible,
                             then: @escaping @MainActor (Value) -> Void) {
        if let kept = cached(query) { return then(kept) }
        ask(query, at: priority) { answer in
            if let stored = answer as? Stored<Value> { then(stored.value) }
        }
    }

    /// The answer to `query`: the kept one, else asked on the system lane at `priority` (raised to the caller's).
    ///
    /// - Throws: `CancellationError` when the caller was cancelled before the question started, or quit dropped it.
    public func value<Value>(_ query: WorkspaceQuery<Value>, priority: WorkPriority = .userVisible) async throws -> Value {
        if let kept = cached(query) { return kept }
        let system = self.system
        let value = try await work.run(priority, mayBlock: .system) { query.ask(system) }
        store(value, for: query.key)
        return value
    }

    /// Sets `item`'s image to the answer of `query`: in this turn when it is kept, else when the system lane answers
    /// (AppKit redraws an open menu's item).
    public func image(_ query: WorkspaceQuery<NSImage>, into item: NSMenuItem, priority: WorkPriority = .userBlocking) {
        value(query, priority: priority) { [weak item] image in item?.image = image }
    }

    /// Asks every question of `queries` that has no kept answer and is not on the lane yet, so the rows about to
    /// show read their answers from ``cached(_:)``.
    public func prefetch<Value>(_ queries: [WorkspaceQuery<Value>], priority: WorkPriority = .bestEffort) {
        for query in queries where entries[query.key] == nil { ask(query, at: priority) }
    }

    /// Drops every kept answer (a question on the lane still stores its answer).
    public func removeAll() {
        entries.removeAll()
    }

    /// Puts `query` on the system lane unless it is there already, with `reply` among its waiters.
    private func ask<Value>(_ query: WorkspaceQuery<Value>, at priority: WorkPriority,
                            reply: (@MainActor (any Sendable) -> Void)? = nil) {
        let key = query.key
        if asking[key] != nil {
            if let reply { asking[key]?.append(reply) }
            return
        }
        asking[key] = reply.map { [$0] } ?? []
        let system = self.system
        work.run(priority, mayBlock: .system) { query.ask(system) }
            .reply(on: mainWork, class: .visible, owner: owner) { [weak self] value in
                self?.answered(value, for: key)
            }
    }

    private func answered<Value: Sendable>(_ value: Value, for key: WorkspaceQueryKey) {
        store(value, for: key)
        let replies = asking.removeValue(forKey: key) ?? []
        let answer = Stored(value: value)
        for reply in replies { reply(answer) }
    }

    private func store<Value: Sendable>(_ value: Value, for key: WorkspaceQueryKey) {
        reads += 1
        entries[key] = Entry(value: Stored(value: value), asked: now(), used: reads)
        guard entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { return }
        entries.removeValue(forKey: oldest)
    }
}
