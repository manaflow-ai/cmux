import CmuxNextCompat
public import Foundation

/// The New Tab page's saved environments (``AgentPaneEnvironment``), kept on this Mac in
/// `environments.json` beside the app's sidebar snapshot (the tag's state): read once, written
/// whole (atomically, owner-only, as the folders and machines a user works on are their own). An
/// actor, so the file IO never runs on the main actor.
public actor SavedEnvironments: AgentPaneEnvironmentStoring {
    /// The actor's own serial queue: its file calls block this queue, never a cooperative pool thread
    /// (Chrome runs file work on a MayBlock sequence, base/task/task_traits.h).
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.next.agent-pane.saved-environments", qos: .userInitiated)

    /// Runs the actor on ``queue``.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Most environments kept; a save past it is refused.
    static let maximumCount = 200

    nonisolated enum Failure: Error { case invalid, full, unwritable, unreadable }

    private let url: URL
    private let now: @Sendable () -> Date
    private var loaded: [AgentPaneEnvironment]?
    /// Entries this build cannot read (a newer build's kind, a hand edit): kept as they were and
    /// written back with every save, so an older build never drops them.
    private var foreign: [Any] = []
    /// The file is there but could not be read (its permissions, an IO error): nothing is cached
    /// and no save or remove may replace it, so the user's environments are never lost to a
    /// passing failure.
    private var unreadable = false

    /// The store kept in `url` (`environments.json` beside the app's sidebar snapshot).
    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    public func list() -> [AgentPaneEnvironment] {
        environments().sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    public func save(_ environment: AgentPaneEnvironment) throws -> AgentPaneEnvironment {
        guard var kept = environment.validated() else { throw Failure.invalid }
        var all = environments()
        guard !unreadable else { throw Failure.unreadable }
        kept.id = kept.id ?? UUID().uuidString
        // Always after every kept one, so the list order is the order of the saves.
        let latest = all.compactMap(\.updatedAt).max() ?? 0
        kept.updatedAt = max(Int64((now().timeIntervalSince1970 * 1000).rounded()), latest + 1)
        if let index = all.firstIndex(where: { $0.id == kept.id }) {
            all[index] = kept
        } else {
            guard all.count + foreign.count < Self.maximumCount else { throw Failure.full }
            all.append(kept)
        }
        try write(all)
        return kept
    }

    public func remove(id: String) throws {
        var all = environments()
        guard !unreadable else { throw Failure.unreadable }
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all.remove(at: index)
        try write(all)
    }

    /// The kept list, read from the file the first time, entry by entry: one this build cannot
    /// read (or that no longer validates) is left out of the list but kept in the file. A file
    /// that is not a list of environments at all reads as empty and is replaced by the next save; a
    /// file that is there but cannot be read reads as empty and is kept (`unreadable`).
    private func environments() -> [AgentPaneEnvironment] {
        if let loaded { return loaded }
        let data: Data?
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            data = nil
        } catch {
            unreadable = true
            return []
        }
        unreadable = false
        let document = data.flatMap { try? JSONSerialization.blockingJSONObject(with: $0) } as? [String: Any]
        var valid: [AgentPaneEnvironment] = []
        for entry in document?["environments"] as? [Any] ?? [] {
            let decoded = (try? JSONSerialization.data(withJSONObject: entry))
                .flatMap { try? JSONDecoder().blockingDecode(AgentPaneEnvironment.self, from: $0) }?
                .validated()
            if let decoded, decoded.id != nil { valid.append(decoded) } else { foreign.append(entry) }
        }
        loaded = valid
        return valid
    }

    private func write(_ all: [AgentPaneEnvironment]) throws {
        let entries = try all.map { try JSONSerialization.blockingJSONObject(with: JSONEncoder().encode($0)) } + foreign
        let data = try JSONSerialization.data(withJSONObject: ["environments": entries], options: [.prettyPrinted, .sortedKeys])
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Owner-only before any byte lands: the temporary file is made 0600, then renamed over.
        let temporary = directory.appending(path: ".environments-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.unwritable
        }
        do {
            let handle = try FileHandle.blockingForWriting(to: temporary)
            do {
                try handle.blockingWrite(contentsOf: data)
                try handle.blockingSynchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // A plain rename: the new file's own 0600 mode replaces whatever the old one had.
            // SAFETY: rename reads the NUL-terminated copies of the two paths made for the call.
            guard unsafe blockingRename(temporary.path, url.path) == 0 else { throw Failure.unwritable }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        loaded = all
    }
}
