public import AppKit
public import CmuxNextCompatAppKit
public import UniformTypeIdentifiers

/// One Launch Services or icon question ``WorkspaceQueries`` answers and keeps: its key, whether a kept answer goes
/// stale (an app installed or removed since changes it; an icon does not), whether the answer is kept at all, and the
/// blocking query that answers it.
public nonisolated struct WorkspaceQuery<Value: Sendable>: Sendable {
    let key: WorkspaceQueryKey
    let refreshes: Bool
    let keeps: Bool
    let ask: @Sendable (any WorkspaceQuerying) -> Value

    init(key: WorkspaceQueryKey, refreshes: Bool, keeps: Bool = true, ask: @escaping @Sendable (any WorkspaceQuerying) -> Value) {
        self.key = key
        self.refreshes = refreshes
        self.keeps = keeps
        self.ask = ask
    }

    /// The same question, asked on the lane and shared by its callers meanwhile, with its answer not kept: for a
    /// caller that keeps the answer in its own bounded store (the Files pane's package and type icons), so each
    /// image has one owner and that owner's memory release frees it.
    public var unkept: Self {
        Self(key: key, refreshes: refreshes, keeps: false, ask: ask)
    }
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

    /// An icon answer: kept in the icon table, apart from the app answers.
    var isIcon: Bool {
        switch self {
        case .iconForFile, .iconForType: return true
        default: return false
        }
    }
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

// memory: bounded: at most `capacity` app answers (256 by default) and `iconCapacity` icons (256 by default), each
// table dropping its least recently read first; an app answer is one app URL or at most a few dozen app URLs, an icon
// one image at one size. The icons are a memory consumer once registered (``registerMemoryConsumer(with:)``).
/// The app's Launch Services and icon answers: which app opens a link, a file or a type, where an app is, and the
/// icon of a file, an app or a type. Each question is asked on the system lane of ``BackgroundWork`` through the
/// checked seams (``WorkspaceQuerying``), never on the main thread, and its answer is kept in a bounded
/// least-recently-used table on the main actor. A menu or a list reads kept answers synchronously
/// (``cached(_:)``), asks for the missing ones with a reply (``value(_:priority:then:)``) or an await
/// (``value(_:priority:)``), and warms the rows it is about to show (``prefetch(_:priority:)``).
///
/// This is Chrome's `IconManager` (chrome/browser/icon_manager.cc): a per-process icon cache on the UI thread whose
/// misses an `IconLoader` fills on a `MayBlock` thread pool sequence and replies to the UI thread. As there, one
/// question in flight serves every caller that asks it meanwhile; a later caller that waits more raises it
/// (Chrome's `UpdateableSequencedTaskRunner::UpdatePriority`, base/task/updateable_sequenced_task_runner.h), so an
/// open menu never waits behind a best-effort warm-up that the startup fence holds.
///
/// Icons are kept apart from the app answers, so a folder of a few hundred apps never drops the browser and Open With
/// lists a menu reads. A caller that keeps an image in its own store asks ``WorkspaceQuery/unkept``.
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

    /// Kept answers; past `limit` (at most `capacity`) the least recently read go first.
    private struct Table {
        let capacity: Int
        var limit: Int
        var entries: [WorkspaceQueryKey: Entry] = [:]

        init(capacity: Int) {
            self.capacity = capacity
            limit = capacity
        }

        /// Keeps `entry`, then drops the least recently read past `limit` (one O(n) scan per drop; an insert drops at
        /// most one unless the limit was just lowered).
        mutating func insert(_ entry: Entry, for key: WorkspaceQueryKey) {
            entries[key] = entry
            while entries.count > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
                entries.removeValue(forKey: oldest)
            }
        }

        /// Drops the least recently read entries until at most `limit` are left, checking `isExpired` before each.
        /// True when the bound holds.
        mutating func trim(until isExpired: () -> Bool = { false }) -> Bool {
            guard entries.count > limit else { return true }
            for key in entries.sorted(by: { $0.value.used < $1.value.used }).map(\.key) {
                guard entries.count > limit else { return true }
                if isExpired() { return false }
                entries.removeValue(forKey: key)
            }
            return entries.count <= limit
        }
    }

    /// A question on the lane: its item (a later caller that waits more raises it), the priority it runs at, and the
    /// replies waiting for its answer.
    private struct Asking {
        let handle: WorkHandle<Void>
        var priority: WorkPriority
        var replies: [@MainActor (any Sendable) -> Void]
    }

    /// The estimated bytes of one kept icon (32 points at 2x, 4 bytes a pixel), for the memory report.
    static let iconBytes = 64 * 64 * 4

    private let work: BackgroundWork
    private let mainWork: MainWorkScheduler
    private let system: any WorkspaceQuerying
    private let refreshAfter: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private let owner: MainTaskOwner
    private var answers: Table
    private var icons: Table
    private var asking: [WorkspaceQueryKey: Asking] = [:]
    private var reads: UInt64 = 0
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - work: The app's lanes; questions run on its system lane.
    ///   - mainWork: The main-thread scheduler that answers come back on (class `visible`).
    ///   - system: The blocking queries (tests pass a fake).
    ///   - capacity: The most app answers kept (at least 1).
    ///   - iconCapacity: The most icons kept at the full memory limit (at least 1).
    ///   - refreshAfter: How old an app answer may be before a read asks again.
    ///   - now: The clock reads use (tests pass a manual one).
    public init(work: BackgroundWork, mainWork: MainWorkScheduler, system: any WorkspaceQuerying = SystemWorkspaceQuerying(),
                capacity: Int = 256, iconCapacity: Int = 256, refreshAfter: Duration = .seconds(60),
                now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.work = work
        self.mainWork = mainWork
        self.system = system
        answers = Table(capacity: max(1, capacity))
        icons = Table(capacity: max(1, iconCapacity))
        self.refreshAfter = refreshAfter
        self.now = now
        owner = mainWork.board.owner("workspace.queries")
    }

    /// The number of kept app answers.
    public var count: Int { answers.entries.count }

    /// The number of kept icons.
    public var iconCount: Int { icons.entries.count }

    /// Registers the kept icons with the app's memory coordinator (once; a later call replaces the registration).
    ///
    /// - Parameter registry: The memory coordinator.
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// The kept answer to `query`, or nil when it was not asked yet (or was dropped). A stale app answer is
    /// returned and asked again in the background.
    public func cached<Value>(_ query: WorkspaceQuery<Value>) -> Value? {
        guard var entry = entry(query.key), let stored = entry.value as? Stored<Value> else { return nil }
        reads += 1
        entry.used = reads
        setEntry(entry, for: query.key)
        if query.refreshes, now() - entry.asked >= refreshAfter { ask(query, at: .bestEffort) }
        return stored.value
    }

    /// Calls `then` with the answer to `query`: in this turn when it is kept, else on main once the system lane
    /// answers (posted in class `visible` for `owner`'s screen update). A question already on the lane is not
    /// asked twice; it runs at `priority` from now on when that is higher.
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
        store(value, for: query)
        return value
    }

    /// Sets `item`'s image to the answer of `query`: in this turn when it is kept, else when the system lane answers
    /// (AppKit redraws an open menu's item).
    public func image(_ query: WorkspaceQuery<NSImage>, into item: NSMenuItem, priority: WorkPriority = .userBlocking) {
        value(query, priority: priority) { [weak item] image in item?.image = image }
    }

    /// Asks every question of `queries` that has no kept answer, so the rows about to show read their answers from
    /// ``cached(_:)``. A question already on the lane is not asked twice; it is raised when `priority` is higher.
    public func prefetch<Value>(_ queries: [WorkspaceQuery<Value>], priority: WorkPriority = .bestEffort) {
        for query in queries where entry(query.key) == nil { ask(query, at: priority) }
    }

    /// Drops every kept answer and icon (a question on the lane still stores its answer).
    public func removeAll() {
        answers.entries.removeAll()
        icons.entries.removeAll()
    }

    private func entry(_ key: WorkspaceQueryKey) -> Entry? {
        key.isIcon ? icons.entries[key] : answers.entries[key]
    }

    private func setEntry(_ entry: Entry, for key: WorkspaceQueryKey) {
        if key.isIcon { icons.entries[key] = entry } else { answers.entries[key] = entry }
    }

    /// Puts `query` on the system lane unless it is there already, with `reply` among its waiters; a question already
    /// there runs at `priority` from now on when that is higher.
    private func ask<Value>(_ query: WorkspaceQuery<Value>, at priority: WorkPriority,
                            reply: (@MainActor (any Sendable) -> Void)? = nil) {
        let key = query.key
        if var waiting = asking[key] {
            if let reply { waiting.replies.append(reply) }
            if priority > waiting.priority {
                waiting.priority = priority
                waiting.handle.raise(to: priority)
            }
            asking[key] = waiting
            return
        }
        let system = self.system, mainWork = self.mainWork, owner = self.owner
        let handle = work.runHandle(priority, mayBlock: .system) { [weak self] in
            let value = query.ask(system)
            mainWork.postFromAnyThread(.visible, owner: owner) { [weak self] in self?.answered(value, for: query) }
        }
        asking[key] = Asking(handle: handle, priority: priority, replies: reply.map { [$0] } ?? [])
    }

    private func answered<Value: Sendable>(_ value: Value, for query: WorkspaceQuery<Value>) {
        store(value, for: query)
        let replies = asking.removeValue(forKey: query.key)?.replies ?? []
        let answer = Stored(value: value)
        for reply in replies { reply(answer) }
    }

    private func store<Value: Sendable>(_ value: Value, for query: WorkspaceQuery<Value>) {
        guard query.keeps else { return }
        reads += 1
        let entry = Entry(value: Stored(value: value), asked: now(), used: reads)
        if query.key.isIcon { icons.insert(entry, for: query.key) } else { answers.insert(entry, for: query.key) }
    }
}

/// The kept icons are one lossless consumer: each comes back from `NSWorkspace` the next time a row or a menu asks.
/// The app answers are a few kilobytes of URLs and stay.
extension WorkspaceQueries: MemoryConsumer {
    /// Nothing to write back and one system call each to make again.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .small,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .cheap,
        releaseCPUCost: .low,
        isStateful: false,
        supportsMemoryLimit: true
    )

    /// The consumer's name in the memory report.
    public static let memoryConsumerName = "workspace-icons"

    /// Scales the icon bound; frees nothing (the next icon drops the oldest past it).
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        icons.limit = limit.scale(icons.capacity)
    }

    /// Drops the least recently read icons until the bound holds or the slice ends.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        return icons.trim(until: { slice.isExpired }) ? .done : .more
    }

    /// The icons' estimated bytes; the entries are the icons.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: icons.entries.count * Self.iconBytes, entries: icons.entries.count)
    }
}
