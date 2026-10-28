import Darwin
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

    /// Records writer ownership outside the chat folder before a write, clear or prune can
    /// remove it. Independent marker files let different chat queues claim keys concurrently.
    public static func preserveOwnership(of name: String, in artifactDirectory: URL) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw MigrationError.invalidOwnedName
        }
        let manager = FileManager.checked
        let root = artifactDirectory.deletingLastPathComponent()
        let artifact = artifactDirectory.lastPathComponent
        if manager.fileExists(atPath: root.appending(path: ".adopted-v1-\(artifact)").path) { return }
        let markers = root.appending(path: ".owned-v1-\(artifact)")
        try manager.createDirectory(at: markers, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try settle(markers.appending(path: name), fileManager: manager)
    }

    /// A whole-snapshot writer or consumer supersedes legacy copies before mutating its data.
    /// Run on the writer's existing files owner; failure must leave the current snapshot intact.
    public static func markCurrent(_ names: [String], in directory: URL) throws {
        let manager = FileManager.checked
        guard names.allSatisfy({ artifacts.contains($0) }) else { throw MigrationError.invalidOwnedName }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in names { try settle(directory.appending(path: ".adopted-v1-\(name)"), fileManager: manager) }
    }

    /// Adopts each draft artifact from the newest prior build root. Draft dictionaries merge
    /// missing keys only; other existing artifacts and all source roots remain intact.
    public static func adopt(from roots: [URL], to destination: URL,
                             fileManager: CheckedFileManager = FileManager.checked) {
        adopt(from: roots, to: destination, fileManager: fileManager) { source, target in
            try fileManager.copyItem(at: source, to: target)
        }
    }

    static func adopt(from roots: [URL], to destination: URL, fileManager: CheckedFileManager = FileManager.checked,
                      renameItem: ((URL, URL, UInt32) -> Int32)? = nil,
                      copyItem: (URL, URL) throws -> Void) {
        guard !fileManager.fileExists(atPath: destination.appending(path: ".adopted-v1").path) else { return }
        let staging = destination.deletingLastPathComponent().appending(path: ".draft-adoption-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: destination, to: staging)
            } else {
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }
            try adoptArtifacts(from: roots, staging: staging, destination: destination,
                               fileManager: fileManager, copyItem: copyItem)
            let exists = fileManager.fileExists(atPath: destination.path)
            if exists {
                let attributes = try fileManager.attributesOfItem(atPath: destination.path)
                    .filter { [FileAttributeKey.posixPermissions, .creationDate, .modificationDate, .ownerAccountID, .groupOwnerAccountID].contains($0.key) }
                try fileManager.setAttributes(attributes, ofItemAtPath: staging.path)
            }
            // A single same-volume rename publishes data and tombstones together. On failure,
            // neither path changes; on exchange success, only our staging name holds the old root.
            let publish = renameItem ?? renameDirectory
            guard publish(staging, destination, exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)) == 0 else { return }
        } catch {
            // The live root remains intact if staging fails; a later launch can retry.
        }
    }

    private static func renameDirectory(_ source: URL, _ target: URL, _ flags: UInt32) -> Int32 {
        assertBlockingAllowed(.fileIO)
        return renamex_np(source.path, target.path, flags)
    }

    private static func adoptArtifacts(from roots: [URL], staging: URL, destination: URL,
                                       fileManager: CheckedFileManager, copyItem: (URL, URL) throws -> Void) throws {
        var failed = false
        for artifact in artifacts {
            let settled = staging.appending(path: ".adopted-v1-\(artifact)")
            // The marker also protects a later intentional removal from legacy resurrection.
            guard !fileManager.fileExists(atPath: settled.path) else { continue }
            let target = staging.appending(path: artifact)
            var owned = Set<String>()
            if artifact == "agent-draft-attachments" || artifact == "agent-pane-wake-attachments" {
                let ledger = staging.appending(path: ".owned-v1-\(artifact).json")
                if fileManager.fileExists(atPath: ledger.path) {
                    owned = Set(try JSONDecoder().decode([String].self, from: Data(blockingContentsOf: ledger)))
                }
                let markers = staging.appending(path: ".owned-v1-\(artifact)")
                if fileManager.fileExists(atPath: markers.path) {
                    owned.formUnion(try fileManager.contentsOfDirectory(atPath: markers.path))
                }
                let current = destination.appending(path: artifact)
                if fileManager.fileExists(atPath: current.path) {
                    owned.formUnion(try fileManager.contentsOfDirectory(atPath: current.path))
                }
                // Current chat names remain owned even if source copying fails and the user
                // removes that chat's folder before the next retry.
                try JSONEncoder().encode(owned.sorted()).blockingWrite(to: ledger, options: [.atomic])
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
            }
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
                        try copyMissing(from: source, to: target, fileManager: fileManager, copyItem: copyItem, owned: owned)
                    }
                }
                try settle(settled, fileManager: fileManager)
            } catch {
                failed = true
                // Discard every copied child of a failed artifact; preserve only the live current data.
                if fileManager.fileExists(atPath: settled.path) { try fileManager.removeItem(at: settled) }
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                let current = destination.appending(path: artifact)
                if fileManager.fileExists(atPath: current.path) { try fileManager.copyItem(at: current, to: target) }
            }
        }
        if !failed { try settle(staging.appending(path: ".adopted-v1"), fileManager: fileManager) }
    }

    private static func settle(_ marker: URL, fileManager: CheckedFileManager) throws {
        try Data("1".utf8).blockingWrite(to: marker, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private enum MigrationError: Error { case invalidDraftDictionary, invalidOwnedName }

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
                                    copyItem: (URL, URL) throws -> Void, owned: Set<String> = []) throws {
        let sourceIsDirectory = (try? source.blockingResourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if sourceIsDirectory {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let destination = target.appending(path: child.lastPathComponent)
                if !owned.contains(child.lastPathComponent) && !isNonEmpty(destination, fileManager: fileManager) {
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
