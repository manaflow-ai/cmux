public import Foundation

public enum DraftStateMigration {
    public static let directoryName = "drafts-v1"
    public static let artifacts = [
        "agent-draft-attachments",
        "agent-pane-wake-states.json",
        "agent-pane-wake-attachments",
        "agent-unsent-drafts.json",
        "agent-composer-drafts.json",
        "agent-queued-edits.json",
        "quick-composer-draft.json",
    ]

    /// Adopts each draft artifact from the newest prior build root. Draft dictionaries merge
    /// missing keys only; other existing artifacts and all source roots remain intact.
    public static func adopt(from roots: [URL], to destination: URL,
                             fileManager: CheckedFileManager = FileManager.checked) {
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        let marker = destination.appending(path: ".adopted-v1")
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        var failed = false
        for artifact in artifacts {
            let target = destination.appending(path: artifact)
            let source = roots
                .filter { $0.standardizedFileURL != destination.standardizedFileURL }
                .map { $0.appending(path: artifact) }
                .filter { isNonEmpty($0, fileManager: fileManager) }
                .max { modificationDate($0, fileManager: fileManager) < modificationDate($1, fileManager: fileManager) }
            guard let source else { continue }
            do {
                if artifact == "agent-unsent-drafts.json" || artifact == "agent-composer-drafts.json" {
                    try mergeDrafts(from: source, to: target, unsent: artifact == "agent-unsent-drafts.json", fileManager: fileManager)
                } else if artifact != "quick-composer-draft.json" || !fileManager.fileExists(atPath: target.path) {
                    try copyMissing(from: source, to: target, fileManager: fileManager)
                }
            } catch {
                failed = true
                // A broken source never blocks launch; the next launch can retry it.
            }
        }

        if !failed {
            try? Data("1".utf8).blockingWrite(to: marker, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
    }

    /// Recovers only composer_draft fields from old daemon session metadata. It does
    /// not move, rewrite or adopt any daemon state.
    public static func adoptComposerDrafts(from homes: [URL], to destination: URL,
                                           fileManager: CheckedFileManager = FileManager.checked) {
        let file = destination.appending(path: "agent-composer-drafts.json")
        var drafts: [String: String] = [:]
        if fileManager.fileExists(atPath: file.path) {
            guard let data = try? Data(blockingContentsOf: file),
                  let existing = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            drafts = existing
        }
        var changed = false
        // The former Quick store was one JSON string. Its fixed key now shares this store.
        if drafts["quick-composer-v1"] == nil,
           let data = try? Data(blockingContentsOf: destination.appending(path: "quick-composer-draft.json")),
           let text = try? JSONDecoder().decode(String.self, from: data) {
            drafts["quick-composer-v1"] = text
            changed = true
        }
        var latest: [String: (date: Date, text: String?)] = [:]
        for home in homes {
            guard let sessions = try? fileManager.contentsOfDirectory(
                at: home.appending(path: "sessions"), includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for session in sessions {
                let metadata = session.appending(path: "session.json")
                guard let data = try? Data(blockingContentsOf: metadata),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = object["id"] as? String else { continue }
                let date = (try? fileManager.attributesOfItem(atPath: metadata.path)[.modificationDate] as? Date) ?? .distantPast
                if let previous = latest[id], previous.date >= date { continue }
                latest[id] = (date, object["composerDraft"] as? String)
            }
        }
        for (id, (_, text)) in latest where drafts[id] == nil {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            drafts[id] = text
            changed = true
        }
        guard changed else { return }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(drafts).blockingWrite(to: file, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { }
    }

    private enum MigrationError: Error { case invalidDraftDictionary }

    /// Unsent drafts were strings before attachment records. Keep pure legacy files in that
    /// format; if records are present, promote strings so the record decoder can read every key.
    private static func mergeDrafts(from source: URL, to target: URL, unsent: Bool, fileManager: CheckedFileManager) throws {
        var drafts = try draftDictionary(at: source, unsent: unsent)
        if fileManager.fileExists(atPath: target.path) {
            let existing = try draftDictionary(at: target, unsent: unsent)
            drafts.merge(existing) { _, current in current }
            if drafts.count == existing.count { return }
        }
        if unsent, drafts.values.contains(where: { $0 is [String: Any] }) {
            drafts = drafts.mapValues { value in
                if let text = value as? String { return ["text": text, "attachments": []] as [String: Any] }
                return value
            }
        }
        try JSONSerialization.data(withJSONObject: drafts, options: [.sortedKeys]).blockingWrite(to: target, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static func draftDictionary(at file: URL, unsent: Bool) throws -> [String: Any] {
        let data = try Data(blockingContentsOf: file)
        guard let drafts = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              drafts.values.allSatisfy({ value in
                  if value is String { return true }
                  guard unsent, let record = value as? [String: Any] else { return false }
                  return record["text"] is String && record["attachments"] is [Any]
              }) else { throw MigrationError.invalidDraftDictionary }
        return drafts
    }

    private static func copyMissing(from source: URL, to target: URL, fileManager: CheckedFileManager) throws {
        let sourceIsDirectory = (try? source.blockingResourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if sourceIsDirectory {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
                let destination = target.appending(path: child.lastPathComponent)
                if !isNonEmpty(destination, fileManager: fileManager) {
                    try copyMissing(from: child, to: destination, fileManager: fileManager)
                }
            }
            return
        }
        guard !isNonEmpty(target, fileManager: fileManager) else { return }
        try fileManager.copyItem(at: source, to: target)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    private static func isNonEmpty(_ url: URL, fileManager: CheckedFileManager) -> Bool {
        guard let values = try? url.blockingResourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
              fileManager.fileExists(atPath: url.path) else { return false }
        if values.isDirectory == true {
            return (try? fileManager.contentsOfDirectory(atPath: url.path).isEmpty) == false
        }
        return (values.fileSize ?? 0) > 0
    }

    private static func modificationDate(_ url: URL, fileManager: CheckedFileManager) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }
}
