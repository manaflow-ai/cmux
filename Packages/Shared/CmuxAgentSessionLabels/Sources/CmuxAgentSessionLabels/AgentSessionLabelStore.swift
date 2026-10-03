public import Foundation

/// Reads and writes the cmux-owned session labels for one state directory.
///
/// `cmux sessions` runs with no socket and reads agent state from disk, so a
/// label has to be readable and writable with no cmux running. This store is
/// that: one JSON document under the state directory, written atomically under a
/// cross-process lock, with no dependency on the app.
///
/// ```swift
/// let store = AgentSessionLabelStore.inStateDirectory(stateDirectory)
/// let key = try AgentSessionLabelKey(agent: "codex", sessionID: sessionID)
/// try await store.setLabel("auditing the socket rows", for: key)
/// ```
///
/// A test points it at a directory of its own and needs nothing else:
///
/// ```swift
/// let directory = URL(fileURLWithPath: NSTemporaryDirectory())
///     .appendingPathComponent(UUID().uuidString)
/// let store = AgentSessionLabelStore.inStateDirectory(directory)
/// ```
public actor AgentSessionLabelStore {
    /// The file name this store owns inside a state directory.
    public static let fileName = "agent-session-labels.json"

    /// The store for the given state directory, at its conventional file name.
    ///
    /// - Parameter directory: a cmux state directory, which need not exist yet.
    /// - Returns: a store for the labels file in it.
    public static func inStateDirectory(_ directory: URL) -> AgentSessionLabelStore {
        AgentSessionLabelStore(fileURL: directory.appendingPathComponent(fileName))
    }

    /// How long a write waits for another writer before it gives up.
    ///
    /// Long enough that an ordinary contended write always wins, short enough
    /// that a command line reports a stuck peer rather than hanging behind it.
    public static let defaultWriteTimeout: Duration = .seconds(10)

    private let fileURL: URL
    private let fileManager: FileManager
    private let writeTimeout: Duration

    /// Creates a store over one file.
    ///
    /// - Parameters:
    ///   - fileURL: the labels file. Its directory is created on first write.
    ///   - fileManager: the file manager directories are created through, here
    ///     and in the write lock. It defaults to `.default` because every caller
    ///     in the app uses that one.
    ///   - writeTimeout: how long a write waits for another writer before it
    ///     fails. The default is the one a person waiting at a command line
    ///     would accept; a test shortens it to reach the failure quickly.
    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        writeTimeout: Duration = AgentSessionLabelStore.defaultWriteTimeout
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.writeTimeout = writeTimeout
        self.path = fileURL.path
    }

    /// The path this store reads and writes, for a message that has to name it.
    ///
    /// Not isolated, because the messages that name it are built on paths that
    /// cannot await, and the value never changes.
    public nonisolated let path: String

    /// Everything the file holds, including the records that could not be read.
    ///
    /// A missing file is no labels, not an error: nothing has written one yet. A
    /// file that cannot be decoded at all is an error, because cmux writes it
    /// whole. A single record that is not a valid label is neither: it is skipped
    /// and reported, so one bad row cannot hide every other agent's labels.
    ///
    /// - Returns: the labels and the skipped records.
    /// - Throws: ``AgentSessionLabelError/malformedStore(path:reason:)`` for a
    ///   document this build cannot read, or
    ///   ``AgentSessionLabelError/unreadableFile(path:reason:)`` when the file is
    ///   there but reading it failed.
    public func snapshot() throws -> AgentSessionLabelSnapshot {
        let document = try read(from: fileURL)
        var labels: [AgentSessionLabelKey: AgentSessionLabel] = [:]
        var unreadable: [AgentSessionLabelSnapshot.UnreadableRecord] = []
        func skip(_ agent: String, _ sessionID: String, _ reason: String) {
            unreadable.append(
                AgentSessionLabelSnapshot.UnreadableRecord(
                    agent: agent, sessionID: sessionID, reason: reason
                )
            )
        }
        for (agent, records) in document.agents {
            for (sessionID, record) in records {
                switch record {
                case let .unreadable(reason, _):
                    skip(agent, sessionID, reason)
                case let .label(text, updatedAt, _):
                    do {
                        let key = try AgentSessionLabelKey(agent: agent, sessionID: sessionID)
                        // The mutators look a record up by the key they would
                        // write, so a record filed under any other spelling of it
                        // is not reachable: returning it would hand back a label
                        // that no write updates and no clear removes.
                        guard key.agent == agent else {
                            throw AgentSessionLabelError.unaddressableRecord(field: "agent")
                        }
                        guard key.sessionID == sessionID else {
                            throw AgentSessionLabelError.unaddressableRecord(field: "session id")
                        }
                        labels[key] = try AgentSessionLabel(text: text, updatedAt: updatedAt)
                    } catch {
                        skip(agent, sessionID, Self.describe(error))
                    }
                }
            }
        }
        // An agent entry that holds no records at all cannot name a session, so
        // it is reported under an empty session id rather than dropped.
        for (agent, _) in document.foreignAgents {
            skip(agent, "", "its records are not a JSON object")
        }
        return AgentSessionLabelSnapshot(
            labels: labels,
            unreadableRecords: AgentSessionLabelSnapshot.ordered(unreadable)
        )
    }

    /// Every stored label, keyed by the session it names.
    ///
    /// - Returns: the readable labels. Records that are not valid labels are
    ///   skipped; ``snapshot()`` is what reports them.
    /// - Throws: what ``snapshot()`` throws.
    public func labels() throws -> [AgentSessionLabelKey: AgentSessionLabel] {
        try snapshot().labels
    }

    /// The label for one session, or nil when it has none.
    ///
    /// This reads and validates the whole file, so a caller drawing many rows
    /// should read ``labels()`` once rather than call this per row.
    ///
    /// - Parameter key: the session to look up.
    /// - Returns: its label, or nil.
    /// - Throws: what ``snapshot()`` throws.
    public func label(for key: AgentSessionLabelKey) throws -> AgentSessionLabel? {
        try labels()[key]
    }

    /// Writes `text` as the label for `key` and returns what was stored.
    ///
    /// The text is validated before the file is opened, so a rejected label
    /// leaves the file as it was rather than half-written. The read and the write
    /// happen under one cross-process lock, so a second writer waits instead of
    /// dropping this record.
    ///
    /// - Parameters:
    ///   - text: the label as typed.
    ///   - key: the session it names.
    ///   - now: when the label was written. It defaults to the current time
    ///     because that is what every caller outside a test wants; a test passes
    ///     a fixed date so its expectations do not move.
    /// - Returns: the label as it was stored, which is what a read returns until
    ///   another writer replaces it.
    /// - Throws: ``AgentSessionLabelError`` for a rejected label, an unreadable
    ///   document or a failed write, and `CancellationError` when the task is
    ///   cancelled while waiting for another writer.
    @discardableResult
    public func setLabel(
        _ text: String, for key: AgentSessionLabelKey, now: Date = Date()
    ) async throws -> AgentSessionLabel {
        let label = try AgentSessionLabel(text: text, updatedAt: now)
        try await withWriteLock { target in
            var document = try read(from: target)
            var records = document.agents[key.agent] ?? [:]
            let extras: [String: Any]
            if case let .label(_, _, existing) = records[key.sessionID] {
                extras = existing
            } else {
                extras = [:]
            }
            records[key.sessionID] = .label(
                text: label.text, updatedAt: label.updatedAt, extras: extras
            )
            document.agents[key.agent] = records
            try write(document, to: target)
        }
        return label
    }

    /// Removes the label for `key`, returning whether there was one.
    ///
    /// A label outlives the session description it was written for: the agent
    /// renames its own thread and the label stays. This is the path that ends
    /// one, so it reports what it did instead of succeeding either way.
    ///
    /// - Parameter key: the session whose label to remove.
    /// - Returns: `true` when a label was removed, `false` when there was none.
    /// - Throws: ``AgentSessionLabelError`` for an unreadable document or a
    ///   failed write, and `CancellationError` when the task is cancelled while
    ///   waiting for another writer.
    @discardableResult
    public func clearLabel(for key: AgentSessionLabelKey) async throws -> Bool {
        var removed = false
        try await withWriteLock { target in
            var document = try read(from: target)
            guard var records = document.agents[key.agent],
                  records.removeValue(forKey: key.sessionID) != nil
            else { return }
            if records.isEmpty {
                document.agents.removeValue(forKey: key.agent)
            } else {
                document.agents[key.agent] = records
            }
            try write(document, to: target)
            removed = true
        }
        return removed
    }

    /// Runs `body` on the locked file while this process owns the write lock.
    ///
    /// The file is resolved once and handed to `body`, because the lock, the read
    /// and the write have to name one file: recomputing it would let a symlink
    /// retargeted in between put the write outside what the lock covers.
    private func withWriteLock(_ body: (URL) throws -> Void) async throws {
        let target = Self.writeURL(for: fileURL, fileManager: fileManager)
        let lock: AgentSessionLabelStoreLock
        do {
            lock = try await AgentSessionLabelStoreLock.acquire(
                target: target, fileManager: fileManager, timeout: writeTimeout
            )
        } catch let error as AgentSessionLabelStoreLockError {
            // The lock's own failures are failures of this write, and a caller
            // printing them needs the file named and one sentence, not a
            // `POSIXError` whose message says only "Permission denied".
            throw AgentSessionLabelError.unwritableFile(path: path, reason: error.reason)
        }
        defer { lock.release() }
        try body(target)
    }

    /// Reads the document at `url`, or says why it is not one.
    ///
    /// Every message names ``path``, the file this store was built for, and not
    /// the resolved file a write lands on: a caller that prints ``path`` in one
    /// message and a caught error in another must not show two paths for one
    /// file.
    private func read(from url: URL) throws -> AgentSessionLabelDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where Self.isMissingFile(error) {
            // Nothing has written a labels file yet, which is no labels.
            return AgentSessionLabelDocument()
        } catch {
            throw AgentSessionLabelError.unreadableFile(
                path: path, reason: Self.describe(error)
            )
        }
        return try AgentSessionLabelDocument.read(data, path: path)
    }

    private func write(_ document: AgentSessionLabelDocument, to target: URL) throws {
        do {
            let data = try document.serialized()
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // `.atomic` writes a temporary file and renames it onto the target, so
            // a reader, which takes no lock, sees either the document that was
            // there or the whole new one and never a half-written file.
            try data.write(to: target, options: .atomic)
        } catch {
            throw AgentSessionLabelError.unwritableFile(
                path: path, reason: Self.describe(error)
            )
        }
    }

    /// Where a write should land for `url`.
    ///
    /// An atomic write renames a temporary file onto the path, which replaces a
    /// symlink with a plain file: a labels file symlinked into a dotfiles
    /// directory would be silently detached from it. Following the link first
    /// means the replace lands on the target and the link survives. The parent is
    /// canonicalized too, so two writers reaching the same file through different
    /// symlinked ancestors take one lock and not two. `CmuxSettings`'s
    /// `JSONConfigStore` does the same thing for the same reason.
    private static func writeURL(for url: URL, fileManager: FileManager) -> URL {
        let canonical = url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL
        guard let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: canonical.path
        ) else {
            return canonical
        }
        let destinationURL = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : canonical.deletingLastPathComponent().appendingPathComponent(destination)
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The sentence form of an error, so a wrapped failure reads as one line.
    private static func describe(_ error: any Error) -> String {
        if let labelError = error as? AgentSessionLabelError { return labelError.description }
        if let lockError = error as? AgentSessionLabelStoreLockError { return lockError.reason }
        // A `CocoaError` interpolates as a struct dump carrying its whole
        // `UserInfo`, and a `POSIXError` as a case name. Both of these reach a
        // command line, so both go through the message a person can read.
        if let cocoa = error as? CocoaError { return cocoa.localizedDescription }
        if let posix = error as? POSIXError { return posix.localizedDescription }
        return "\(error)"
    }

    private static func isMissingFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
            return true
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }
}
