import Foundation

/// The on-disk shape of the labels file, with the reading and writing of it.
///
/// Records nest under their agent rather than under one composite key, so a
/// session id is never parsed out of a string, whatever characters it holds.
///
/// The document is read value by value through `JSONSerialization` instead of
/// `Codable`, for two reasons a synthesized decoder cannot give. A `Decodable`
/// document fails as a unit, so one record written in a shape this build does
/// not read would hide every other agent's labels; here that record is the only
/// thing lost. And a record this build cannot read is kept exactly as it was
/// found, so the next write puts it back instead of deleting a row this build
/// did not understand. A decoder also fails with a `DecodingError` dump, and
/// every failure here has to read as one sentence a command line can print.
struct AgentSessionLabelDocument {
    /// The schema version, so a later shape can be told from this one.
    static let currentVersion = 1

    /// One record, as this build was able to read it.
    enum Record {
        /// A record this build read.
        ///
        /// `extras` holds the fields of the record this build has no meaning
        /// for, so a write preserves them rather than dropping another
        /// program's data.
        case label(text: String, updatedAt: Date, extras: [String: Any])
        /// A record this build could not read, with the JSON it was found as.
        case unreadable(reason: String, raw: Any)
    }

    var version: Int
    var agents: [String: [String: Record]]

    /// Agent entries whose value is not a JSON object of records.
    ///
    /// They cannot hold records, so they are not in ``agents``, and they are
    /// kept here rather than dropped: this build did not write them and a write
    /// of its own must not delete them.
    var foreignAgents: [String: Any]

    init(
        version: Int = AgentSessionLabelDocument.currentVersion,
        agents: [String: [String: Record]] = [:],
        foreignAgents: [String: Any] = [:]
    ) {
        self.version = version
        self.agents = agents
        self.foreignAgents = foreignAgents
    }

    /// Reads `data` as a document, or says in one sentence why it is not one.
    ///
    /// - Parameters:
    ///   - data: the file's bytes.
    ///   - path: the file, for the message. Every failure here names it, because
    ///     the fix is to go and look at that file.
    /// - Returns: the document, including the records that could not be read.
    /// - Throws: ``AgentSessionLabelError/malformedStore(path:reason:)`` when the
    ///   file as a whole is not a document this build reads. A single bad record
    ///   is not that: it comes back as ``Record/unreadable(reason:raw:)``.
    static func read(_ data: Data, path: String) throws -> AgentSessionLabelDocument {
        // A file that exists and holds nothing is not "no labels": that is what a
        // crash between rename and flush leaves, and what `> file` leaves. Reading
        // it as empty would make the next write delete every other record.
        guard !data.isEmpty else {
            throw AgentSessionLabelError.malformedStore(path: path, reason: "the file is empty")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AgentSessionLabelError.malformedStore(path: path, reason: "it is not JSON")
        }
        guard let object = parsed as? [String: Any] else {
            throw AgentSessionLabelError.malformedStore(
                path: path, reason: "its top level is not a JSON object"
            )
        }
        // The version is read before the body, because a later shape is the body
        // failing to read and the version is the part that explains it.
        guard let version = object["version"] as? Int else {
            throw AgentSessionLabelError.malformedStore(
                path: path,
                reason: object["version"] == nil ? "it has no version" : "its version is not a number"
            )
        }
        guard version == currentVersion else {
            throw AgentSessionLabelError.malformedStore(
                path: path,
                reason: "version \(version) is not version \(currentVersion), which this build writes"
            )
        }
        // An absent `agents` is no labels rather than a broken file: it is what an
        // empty document means, and refusing it would fail over nothing.
        let rawAgents = object["agents"] ?? [String: Any]()
        guard let agentsObject = rawAgents as? [String: Any] else {
            throw AgentSessionLabelError.malformedStore(
                path: path, reason: "its agents field is not a JSON object"
            )
        }

        var agents: [String: [String: Record]] = [:]
        var foreignAgents: [String: Any] = [:]
        for (agent, rawRecords) in agentsObject {
            guard let recordsObject = rawRecords as? [String: Any] else {
                foreignAgents[agent] = rawRecords
                continue
            }
            var records: [String: Record] = [:]
            for (sessionID, rawRecord) in recordsObject {
                records[sessionID] = record(from: rawRecord)
            }
            agents[agent] = records
        }
        return AgentSessionLabelDocument(
            version: version, agents: agents, foreignAgents: foreignAgents
        )
    }

    /// The document as bytes, in one order so the file can be diffed.
    ///
    /// - Returns: pretty-printed JSON with sorted keys.
    /// - Throws: whatever `JSONSerialization` throws, which a caller wraps as a
    ///   failed write.
    func serialized() throws -> Data {
        var agentsObject: [String: Any] = foreignAgents
        for (agent, records) in agents {
            var recordsObject: [String: Any] = [:]
            for (sessionID, record) in records {
                switch record {
                case let .label(text, updatedAt, extras):
                    var object = extras
                    object["label"] = text
                    object["updated_at"] = Self.timestamp(updatedAt)
                    recordsObject[sessionID] = object
                case let .unreadable(_, raw):
                    recordsObject[sessionID] = raw
                }
            }
            agentsObject[agent] = recordsObject
        }
        return try JSONSerialization.data(
            withJSONObject: ["version": version, "agents": agentsObject],
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Reads one record, naming what is wrong with it rather than throwing.
    static func record(from raw: Any) -> Record {
        guard let object = raw as? [String: Any] else {
            return .unreadable(reason: "the record is not a JSON object", raw: raw)
        }
        guard let text = object["label"] as? String else {
            return .unreadable(
                reason: object["label"] == nil ? "it has no label" : "its label is not a string",
                raw: raw
            )
        }
        guard let written = object["updated_at"] as? String else {
            return .unreadable(
                reason: object["updated_at"] == nil
                    ? "it has no updated_at"
                    : "its updated_at is not a string",
                raw: raw
            )
        }
        guard let updatedAt = Self.date(from: written) else {
            return .unreadable(
                reason: "\(written) is not an ISO 8601 timestamp", raw: raw
            )
        }
        var extras = object
        extras.removeValue(forKey: "label")
        extras.removeValue(forKey: "updated_at")
        return .label(text: text, updatedAt: updatedAt, extras: extras)
    }

    /// The timestamp form this build writes: whole ISO 8601 seconds, in UTC.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The timestamps other programs write, not only the one this build writes.
    ///
    /// `new Date().toISOString()` and `datetime.now(timezone.utc).isoformat()`
    /// carry fractional seconds, and `datetime.now().isoformat()` carries no
    /// offset at all. Refusing any of those would lose a record a hook wrote
    /// over a spelling cmux itself never produces.
    static func date(from text: String) -> Date? {
        if let date = internetDate(from: text) { return date }
        // No offset means a local time this reader cannot recover, so it is read
        // as UTC. That is a guess, but a label's timestamp only orders rows and
        // says how old a name is, and the alternative is dropping the record.
        if !hasOffset(text) { return internetDate(from: text + "Z") }
        return nil
    }

    private static func internetDate(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// Whether the time part of `text` names a UTC offset.
    private static func hasOffset(_ text: String) -> Bool {
        guard let separator = text.firstIndex(where: { $0 == "T" || $0 == "t" }) else {
            return false
        }
        let time = text[text.index(after: separator)...]
        return time.contains(where: { $0 == "Z" || $0 == "z" || $0 == "+" || $0 == "-" })
    }
}
