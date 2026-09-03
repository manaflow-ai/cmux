public import Foundation

/// File-backed association cache twin of plugin ``associations-<fingerprint>.json``.
///
/// Shares title-lock / heuristic fields so plugin sync after native detach does not
/// thrash display names (L-TITLE-LOCK). Schema version 1 matches
/// ``cmux_herdr_bridge._load_association_map``.
public enum RemoteHerdrAssociationFile {
    public static let schemaVersion = 1

    /// Paths both plugin and native read/write for one fingerprint.
    public static func paths(
        fingerprint: String,
        directories: [URL]
    ) -> [URL] {
        directories.map { $0.appendingPathComponent("associations-\(fingerprint).json") }
    }
}

/// Read/write plugin association JSON (title locks + heuristic flags).
public struct RemoteHerdrAssociationStore: Sendable {
    public var directories: [URL]

    public init(directories: [URL]) {
        self.directories = directories
    }

    /// Load the first readable associations document for *fingerprint*.
    public func load(fingerprint: String) -> [String: Any] {
        for path in RemoteHerdrAssociationFile.paths(
            fingerprint: fingerprint,
            directories: directories
        ) {
            guard let data = try? Data(contentsOf: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["version"] as? Int) == RemoteHerdrAssociationFile.schemaVersion,
                  object["panes"] is [String: Any]
            else { continue }
            return object
        }
        return emptyDocument(fingerprint: fingerprint)
    }

    /// Locked display title for *paneID*, if any.
    public func lockedTitle(fingerprint: String, paneID: String) -> String? {
        guard let panes = load(fingerprint: fingerprint)["panes"] as? [String: Any],
              let entry = panes[paneID] as? [String: Any],
              (entry["title_lock"] as? Bool) == true
        else { return nil }
        let title = (entry["locked_title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    /// Whether *paneID* currently has an active title lock.
    public func isTitleLocked(fingerprint: String, paneID: String) -> Bool {
        lockedTitle(fingerprint: fingerprint, paneID: paneID) != nil
            || {
                guard let panes = load(fingerprint: fingerprint)["panes"] as? [String: Any],
                      let entry = panes[paneID] as? [String: Any]
                else { return false }
                return (entry["title_lock"] as? Bool) == true
            }()
    }

    /// Install a native-title lock (plugin sync must not overwrite).
    @discardableResult
    public func lockTitle(
        fingerprint: String,
        paneID: String,
        title: String,
        authority: String = NestedTitleAuthority.hostSurfacePolicy.rawValue
    ) -> [String: Any] {
        let trimmedPane = paneID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPane.isEmpty, !trimmedTitle.isEmpty else {
            return load(fingerprint: fingerprint)
        }
        var doc = load(fingerprint: fingerprint)
        var panes = (doc["panes"] as? [String: Any]) ?? [:]
        var entry = (panes[trimmedPane] as? [String: Any]) ?? [
            "pane_id": trimmedPane,
            "status_key": "herdr:\(trimmedPane)",
            "association_key": trimmedPane,
        ]
        entry["title_lock"] = true
        entry["locked_title"] = trimmedTitle
        entry["title_authority"] = authority
        panes[trimmedPane] = entry
        doc["panes"] = panes
        doc["host_fingerprint_key"] = fingerprint
        doc["version"] = RemoteHerdrAssociationFile.schemaVersion
        doc["updated_at"] = Date().timeIntervalSince1970
        _ = write(doc, fingerprint: fingerprint)
        return entry
    }

    /// Clear the title lock for *paneID* (keeps other association fields).
    @discardableResult
    public func unlockTitle(fingerprint: String, paneID: String) -> [String: Any]? {
        let trimmedPane = paneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPane.isEmpty else { return nil }
        var doc = load(fingerprint: fingerprint)
        var panes = (doc["panes"] as? [String: Any]) ?? [:]
        guard var entry = panes[trimmedPane] as? [String: Any] else { return nil }
        entry["title_lock"] = false
        entry.removeValue(forKey: "locked_title")
        entry.removeValue(forKey: "title_authority")
        panes[trimmedPane] = entry
        doc["panes"] = panes
        doc["updated_at"] = Date().timeIntervalSince1970
        _ = write(doc, fingerprint: fingerprint)
        return entry
    }

    /// Persist *document* to every state directory (atomic replace).
    @discardableResult
    public func write(_ document: [String: Any], fingerprint: String) -> [URL] {
        var body = document
        body["version"] = RemoteHerdrAssociationFile.schemaVersion
        body["host_fingerprint_key"] = fingerprint
        if body["panes"] == nil { body["panes"] = [String: Any]() }
        if body["mirrors"] == nil { body["mirrors"] = [String: Any]() }
        guard let data = try? JSONSerialization.data(
            withJSONObject: body,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return [] }
        var written: [URL] = []
        for path in RemoteHerdrAssociationFile.paths(
            fingerprint: fingerprint,
            directories: directories
        ) {
            do {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporary = path.appendingPathExtension("tmp")
                try data.write(to: temporary, options: [.atomic])
                try? FileManager.default.removeItem(at: path)
                try FileManager.default.moveItem(at: temporary, to: path)
                written.append(path)
            } catch {
                continue
            }
        }
        return written
    }

    private func emptyDocument(fingerprint: String) -> [String: Any] {
        [
            "version": RemoteHerdrAssociationFile.schemaVersion,
            "panes": [String: Any](),
            "mirrors": [String: Any](),
            "cmux_workspace": NSNull(),
            "host_fingerprint_key": fingerprint,
            "updated_at": NSNull(),
        ]
    }
}
