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

    private let fileURL: URL
    private let fileManager: FileManager

    /// Creates a store over one file.
    ///
    /// - Parameters:
    ///   - fileURL: the labels file. Its directory is created on first write.
    ///   - fileManager: the file manager to create directories through. It
    ///     defaults to `.default` because every caller in the app uses that one,
    ///     and a test overrides it to watch what the store does.
    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
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
        let document = try read()
        var labels: [AgentSessionLabelKey: AgentSessionLabel] = [:]
        var unreadable: [AgentSessionLabelSnapshot.UnreadableRecord] = []
        for (agent, records) in document.agents {
            for (sessionID, record) in records {
                do {
                    let key = try AgentSessionLabelKey(agent: agent, sessionID: sessionID)
                    labels[key] = try AgentSessionLabel(
                        text: record.label, updatedAt: record.updatedAt
                    )
                } catch {
                    unreadable.append(
                        AgentSessionLabelSnapshot.UnreadableRecord(
                            agent: agent,
                            sessionID: sessionID,
                            reason: Self.describe(error)
                        )
                    )
                }
            }
        }
        return AgentSessionLabelSnapshot(
            labels: labels,
            unreadableRecords: unreadable.sorted {
                ($0.agent, $0.sessionID) < ($1.agent, $1.sessionID)
            }
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
    /// - Returns: the stored label, which is what a later read returns.
    /// - Throws: ``AgentSessionLabelError`` for a rejected label, an unreadable
    ///   document or a failed write.
    @discardableResult
    public func setLabel(
        _ text: String, for key: AgentSessionLabelKey, now: Date = Date()
    ) async throws -> AgentSessionLabel {
        let label = try AgentSessionLabel(text: text, updatedAt: now)
        try await withWriteLock {
            var document = try read()
            var records = document.agents[key.agent] ?? [:]
            records[key.sessionID] = AgentSessionLabelDocument.Record(
                label: label.text, updatedAt: label.updatedAt
            )
            document.agents[key.agent] = records
            try write(document)
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
    ///   failed write.
    @discardableResult
    public func clearLabel(for key: AgentSessionLabelKey) async throws -> Bool {
        var removed = false
        try await withWriteLock {
            var document = try read()
            guard var records = document.agents[key.agent],
                  records.removeValue(forKey: key.sessionID) != nil
            else { return }
            if records.isEmpty {
                document.agents.removeValue(forKey: key.agent)
            } else {
                document.agents[key.agent] = records
            }
            try write(document)
            removed = true
        }
        return removed
    }

    /// Runs `body` while this process owns the store's write lock.
    private func withWriteLock(_ body: () throws -> Void) async throws {
        let lock = try await AgentSessionLabelStoreLock.acquire(target: Self.writeURL(
            for: fileURL, fileManager: fileManager
        ))
        defer { lock.release() }
        try body()
    }

    private func read() throws -> AgentSessionLabelDocument {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where Self.isMissingFile(error) {
            return AgentSessionLabelDocument()
        } catch {
            throw AgentSessionLabelError.unreadableFile(
                path: fileURL.path, reason: Self.describe(error)
            )
        }
        // A file that exists and holds nothing is not "no labels": that is what a
        // crash between rename and flush leaves, and what `> file` leaves. Reading
        // it as empty would make the next write delete every other record.
        guard !data.isEmpty else {
            throw AgentSessionLabelError.malformedStore(
                path: fileURL.path, reason: "the file is empty"
            )
        }
        // The version is read on its own first, because a later shape is a decode
        // failure of its own body and the version is the part that explains it.
        let probe: AgentSessionLabelDocument.VersionProbe
        do {
            probe = try JSONDecoder().decode(
                AgentSessionLabelDocument.VersionProbe.self, from: data
            )
        } catch {
            throw AgentSessionLabelError.malformedStore(
                path: fileURL.path, reason: Self.describe(error)
            )
        }
        guard let version = probe.version else {
            throw AgentSessionLabelError.malformedStore(
                path: fileURL.path, reason: "it has no version"
            )
        }
        guard version == AgentSessionLabelDocument.currentVersion else {
            throw AgentSessionLabelError.malformedStore(
                path: fileURL.path,
                reason: "version \(version) is not version "
                    + "\(AgentSessionLabelDocument.currentVersion), which this "
                    + "build writes"
            )
        }
        do {
            return try Self.decoder().decode(AgentSessionLabelDocument.self, from: data)
        } catch {
            throw AgentSessionLabelError.malformedStore(
                path: fileURL.path, reason: Self.describe(error)
            )
        }
    }

    private func write(_ document: AgentSessionLabelDocument) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let target = Self.writeURL(for: fileURL, fileManager: fileManager)
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: target, options: .atomic)
        } catch {
            throw AgentSessionLabelError.unwritableFile(
                path: target.path, reason: Self.describe(error)
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

    /// A decoder that reads the timestamps other programs write.
    ///
    /// The store writes whole ISO 8601 seconds, but a hook written in another
    /// language writes `toISOString()` or `isoformat()`, which carry fractional
    /// seconds. Refusing those would make one foreign record take down the whole
    /// document.
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: text) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "\(text) is not an ISO 8601 timestamp"
                )
            )
        }
        return decoder
    }

    /// The sentence form of an error, so a wrapped failure reads as one line.
    private static func describe(_ error: any Error) -> String {
        if let labelError = error as? AgentSessionLabelError { return labelError.description }
        if let cocoa = error as? CocoaError {
            return cocoa.localizedDescription
        }
        return "\(error)"
    }

    private static func isMissingFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
            return true
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }
}
