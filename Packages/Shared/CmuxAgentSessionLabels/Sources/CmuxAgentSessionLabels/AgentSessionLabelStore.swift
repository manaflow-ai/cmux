import Foundation

/// Reads and writes the cmux-owned session labels for one state directory.
///
/// `cmux sessions` runs with no socket and reads agent state from disk, so a
/// label has to be readable and writable with no cmux running. This store is
/// that: one JSON document under the state directory, written atomically, with
/// no dependency on the app.
public actor AgentSessionLabelStore {
    /// The file name this store owns inside a state directory.
    public static let fileName = "agent-session-labels.json"

    /// The store for the given state directory, at its conventional file name.
    public static func inStateDirectory(_ directory: URL) -> AgentSessionLabelStore {
        AgentSessionLabelStore(fileURL: directory.appendingPathComponent(fileName))
    }

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// The path this store reads and writes, for a message that has to name it.
    public var path: String { fileURL.path }

    /// Every stored label, keyed by the session it names.
    ///
    /// A missing file is no labels, not an error: nothing has written one yet.
    /// A file that cannot be decoded is an error, because only cmux writes this
    /// file and it writes it whole.
    public func labels() throws -> [AgentSessionLabelKey: AgentSessionLabel] {
        let document = try read()
        var result: [AgentSessionLabelKey: AgentSessionLabel] = [:]
        for (agent, records) in document.agents {
            for (sessionID, record) in records {
                let key: AgentSessionLabelKey
                let label: AgentSessionLabel
                do {
                    key = try AgentSessionLabelKey(agent: agent, sessionID: sessionID)
                    label = try AgentSessionLabel(
                        text: record.label, updatedAt: record.updatedAt
                    )
                } catch {
                    throw AgentSessionLabelError.malformedStore(
                        path: fileURL.path,
                        reason: "the record for \(agent)/\(sessionID) is not a valid "
                            + "label: \(error)"
                    )
                }
                result[key] = label
            }
        }
        return result
    }

    /// The label for one session, or nil when it has none.
    public func label(for key: AgentSessionLabelKey) throws -> AgentSessionLabel? {
        try labels()[key]
    }

    /// Writes `text` as the label for `key` and returns what was stored.
    ///
    /// The text is validated first, so a rejected label leaves the file as it
    /// was rather than half-written.
    @discardableResult
    public func setLabel(
        _ text: String, for key: AgentSessionLabelKey, now: Date = Date()
    ) throws -> AgentSessionLabel {
        let label = try AgentSessionLabel(text: text, updatedAt: now)
        var document = try read()
        var records = document.agents[key.agent] ?? [:]
        records[key.sessionID] = AgentSessionLabelDocument.Record(
            label: label.text, updatedAt: label.updatedAt
        )
        document.agents[key.agent] = records
        try write(document)
        return label
    }

    /// Removes the label for `key`, returning whether there was one.
    ///
    /// A label outlives the session description it was written for: the agent
    /// renames its own thread and the label stays. This is the path that ends
    /// one, so it reports what it did instead of succeeding either way.
    @discardableResult
    public func clearLabel(for key: AgentSessionLabelKey) throws -> Bool {
        var document = try read()
        guard var records = document.agents[key.agent],
              records.removeValue(forKey: key.sessionID) != nil
        else { return false }
        if records.isEmpty {
            document.agents.removeValue(forKey: key.agent)
        } else {
            document.agents[key.agent] = records
        }
        try write(document)
        return true
    }

    private func read() throws -> AgentSessionLabelDocument {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where Self.isMissingFile(error) {
            return AgentSessionLabelDocument()
        }
        if data.isEmpty { return AgentSessionLabelDocument() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let document = try decoder.decode(AgentSessionLabelDocument.self, from: data)
            guard document.version == AgentSessionLabelDocument.currentVersion else {
                throw AgentSessionLabelError.malformedStore(
                    path: fileURL.path,
                    reason: "version \(document.version) is not version "
                        + "\(AgentSessionLabelDocument.currentVersion), which this "
                        + "build writes"
                )
            }
            return document
        } catch let error as AgentSessionLabelError {
            throw error
        } catch {
            throw AgentSessionLabelError.malformedStore(
                path: fileURL.path, reason: "\(error)"
            )
        }
    }

    private func write(_ document: AgentSessionLabelDocument) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func isMissingFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
            return true
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }
}
