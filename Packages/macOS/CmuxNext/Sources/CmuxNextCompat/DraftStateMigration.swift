import Foundation

public enum DraftStateMigration {
    public static let directoryName = "drafts-v1"
    public static let artifacts = [
        "agent-draft-attachments",
        "agent-pane-wake-states.json",
        "agent-pane-wake-attachments",
        "agent-unsent-drafts.json",
        "agent-composer-drafts.json",
    ]

    /// Copies each draft artifact from the newest prior build root. Existing destination
    /// artifacts are never overwritten; source roots remain intact for rollback.
    public static func adopt(from roots: [URL], to destination: URL,
                             fileManager: FileManager = .default) {
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
                try copyMissing(from: source, to: target, fileManager: fileManager)
            } catch {
                failed = true
                // A broken source never blocks launch; the next launch can retry it.
            }
        }

        if !failed {
            try? Data("1".utf8).write(to: marker, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
    }

    /// Recovers only composer_draft fields from old daemon session metadata. It does
    /// not move, rewrite or adopt any daemon state.
    public static func adoptComposerDrafts(from homes: [URL], to destination: URL,
                                           fileManager: FileManager = .default) {
        let file = destination.appending(path: "agent-composer-drafts.json")
        var drafts: [String: String] = [:]
        if let data = try? Data(contentsOf: file),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            drafts = existing
        }
        var latest: [String: (date: Date, text: String?)] = [:]
        for home in homes {
            guard let sessions = try? fileManager.contentsOfDirectory(
                at: home.appending(path: "sessions"), includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            }
            for session in sessions {
                let metadata = session.appending(path: "session.json")
                guard let data = try? Data(contentsOf: metadata),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = object["id"] as? String else { continue }
                let date = (try? fileManager.attributesOfItem(atPath: metadata.path)[.modificationDate] as? Date) ?? .distantPast
                if let previous = latest[id], previous.date >= date { continue }
                latest[id] = (date, object["composerDraft"] as? String)
            }
        }
        for (id, (_, text)) in latest where drafts[id] == nil,
            let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[id] = text
        }
        guard !drafts.isEmpty else { return }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(drafts).write(to: file, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { }
    }

    private static func copyMissing(from source: URL, to target: URL, fileManager: FileManager) throws {
        let sourceIsDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
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

    private static func isNonEmpty(_ url: URL, fileManager: FileManager) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
              fileManager.fileExists(atPath: url.path) else { return false }
        if values.isDirectory == true {
            return (try? fileManager.contentsOfDirectory(atPath: url.path).isEmpty) == false
        }
        return (values.fileSize ?? 0) > 0
    }

    private static func modificationDate(_ url: URL, fileManager: FileManager) -> Date {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }
}
