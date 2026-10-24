public import Foundation

/// The client's durable Home cache, one per owner and account
/// (`~/Library/Caches/cmux-home/<owner key>/` on the Mac): a Repository actor.
///
/// On disk it is a small index (`home.json`: the inbox, unsent sends, drafts, scroll anchors and
/// the list of cached windows) plus one file per opened conversation's window
/// (`home-windows/<conversation>.json`, its newest ``windowLimit`` messages). A write is
/// proportional to the change, not to the store: the actor keeps what it last wrote and rewrites
/// the index only when it changed and only the windows that changed (speed-of-sound-DESIGN.md
/// 3.5). Encoding and writing run on the actor, never on the caller's main actor, which hands
/// over a ``HomeCacheState`` of copy-on-write values. A file that does not decode is ignored,
/// since the owner can rebuild everything in it but drafts and unsent sends. An index written
/// whole by an older build (windows inline) still loads.
///
/// ```swift
/// let cache = HomeCache(url: temporaryDirectory.appendingPathComponent("home.json"))
/// try await cache.save(snapshot)
/// let restored = cache.load()
/// ```
///
/// Its executor is its own serial queue, so a path that ends the process next (a forced exit)
/// can run the same commit synchronously, after the write already running
/// (``writeBlocking(_:sequence:writer:)``); everything else awaits the actor.
public actor HomeCache {
    /// Messages kept per opened conversation.
    public static let windowLimit = 200

    /// The index file; the windows are in ``windowsDirectory`` beside it.
    public nonisolated let url: URL
    /// This actor's executor: ``writeBlocking(_:sequence:writer:)`` runs on it with `sync`.
    private nonisolated let queue: DispatchSerialQueue
    /// The files and what they hold; touched only on `queue`.
    private nonisolated let files: HomeCacheFiles

    /// Runs this actor's jobs on `queue` (one serial queue, as any actor's executor is serial).
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(url: URL) {
        self.url = url
        queue = DispatchSerialQueue(label: "com.cmuxterm.home-cache")
        files = HomeCacheFiles(url: url)
    }

    /// `Caches/cmux-home/<owner>/home.json`; `owner` is made a single path component.
    public static func standard(owner: String) -> HomeCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let component = String(owner.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return HomeCache(url: caches.appendingPathComponent("cmux-home/\(component)/home.json"))
    }

    /// `home-windows/` beside `home.json`: one file per cached window.
    public nonisolated var windowsDirectory: URL { files.windowsDirectory }

    /// The cached snapshot, read synchronously (the Home list's first frame needs it before the
    /// owner answers). Nil when there is none or it does not decode; a window whose file is
    /// gone or does not decode is left out.
    public nonisolated func load() -> HomeCacheSnapshot? {
        guard var snapshot = files.readIndex() else { return nil }
        for id in snapshot.windowIDs ?? [] where snapshot.windows[id] == nil {
            if let messages = files.readWindow(id) { snapshot.windows[id] = messages }
        }
        snapshot.windowIDs = nil
        return snapshot
    }

    /// Writes `snapshot` as the newest state (tests, tools): the index and each window that
    /// differs from what is on disk.
    ///
    /// - Throws: `CocoaError(.fileWriteUnknown)` when a file did not reach disk.
    public func save(_ snapshot: HomeCacheSnapshot) throws {
        if !files.commit(HomeCacheState(snapshot)) { throw CocoaError(.fileWriteUnknown) }
    }

    /// Writes `state` unless `writer` already wrote a newer one; true when everything it holds is
    /// on disk (or a newer state replaced it).
    func write(_ state: HomeCacheState, sequence: UInt64, writer: UUID) -> Bool {
        files.write(state, sequence: sequence, writer: writer)
    }

    /// ``write(_:sequence:writer:)`` on the calling thread, after the job already on this actor,
    /// for a path that ends the process next (a forced exit): returns once the files are on disk.
    /// It blocks the caller for one proportional commit; never call it where the process goes on.
    nonisolated func writeBlocking(_ state: HomeCacheState, sequence: UInt64, writer: UUID) -> Bool {
        let files = files
        // concurrency-allow: the forced exit's last write enters this actor's own executor queue
        // synchronously (an actor cannot be entered from a non-async signal path), so it runs after
        // the write already there and before `exit`; nothing on that queue waits for the caller.
        return queue.sync { files.write(state, sequence: sequence, writer: writer) }
    }
}
