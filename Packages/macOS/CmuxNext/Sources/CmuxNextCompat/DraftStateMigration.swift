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
        adopt(from: roots, to: destination, fileManager: fileManager) { source, target in
            try fileManager.copyItem(at: source, to: target)
        }
    }

    static func adopt(from roots: [URL], to destination: URL, fileManager: CheckedFileManager = FileManager.checked,
                      copyItem: (URL, URL) throws -> Void) {
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        let marker = destination.appending(path: ".adopted-v1")
        if fileManager.fileExists(atPath: marker.path) {
            // Upgrade the old global marker into per-artifact tombstones before returning.
            for artifact in artifacts {
                let settled = destination.appending(path: ".adopted-v1-\(artifact)")
                try? settle(settled, fileManager: fileManager)
            }
            return
        }
        var failed = false
        for artifact in artifacts {
            let settled = destination.appending(path: ".adopted-v1-\(artifact)")
            // A settled artifact is a tombstone as well as a completion record: if the person
            // clears its restored data, a later launch must not resurrect the old source.
            guard !fileManager.fileExists(atPath: settled.path) else { continue }
            let target = destination.appending(path: artifact)
            let source = roots
                .filter { $0.standardizedFileURL != destination.standardizedFileURL }
                .map { $0.appending(path: artifact) }
                .filter { isNonEmpty($0, fileManager: fileManager) }
                .max { modificationDate($0, fileManager: fileManager) < modificationDate($1, fileManager: fileManager) }
            do {
                if let source {
                    if artifact == "agent-unsent-drafts.json" || artifact == "agent-composer-drafts.json" {
                        try mergeDrafts(from: source, to: target, unsent: artifact == "agent-unsent-drafts.json", fileManager: fileManager)
                    } else if artifact != "quick-composer-draft.json" || !fileManager.fileExists(atPath: target.path) {
                        try copyMissing(from: source, to: target, fileManager: fileManager, copyItem: copyItem)
                    }
                }
                try settle(settled, fileManager: fileManager)
            } catch {
                failed = true
                // A broken source or marker never blocks launch; the next launch can retry it.
            }
        }

        if !failed && artifacts.allSatisfy({ fileManager.fileExists(atPath: destination.appending(path: ".adopted-v1-\($0)").path) }) {
            try? Data("1".utf8).blockingWrite(to: marker, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
    }

    private static func settle(_ marker: URL, fileManager: CheckedFileManager) throws {
        try Data("1".utf8).blockingWrite(to: marker, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
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

    private static func copyMissing(from source: URL, to target: URL, fileManager: CheckedFileManager,
                                    copyItem: (URL, URL) throws -> Void) throws {
        let sourceIsDirectory = (try? source.blockingResourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if sourceIsDirectory {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let destination = target.appending(path: child.lastPathComponent)
                if !isNonEmpty(destination, fileManager: fileManager) {
                    try copyMissing(from: child, to: destination, fileManager: fileManager, copyItem: copyItem)
                }
            }
            return
        }
        guard !isNonEmpty(target, fileManager: fileManager) else { return }
        try copyItem(source, target)
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
