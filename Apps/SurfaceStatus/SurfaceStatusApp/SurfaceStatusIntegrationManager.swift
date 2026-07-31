import CryptoKit
import Darwin
import Foundation

/// Coordinates the independently reusable adapter managers as one user-visible
/// transaction. Child managers retain their own ownership checks; this journal
/// supplies the missing cross-manager crash/rollback boundary.
struct SurfaceStatusIntegrationManager: Sendable {
    private struct Journal: Codable, Sendable {
        enum State: String, Codable, Sendable { case applying, committed }
        struct Snapshot: Codable, Sendable {
            let id: String
            let existed: Bool
            let data: Data?
            let permissions: Int?
        }

        let schemaVersion: Int
        let transactionID: UUID
        let operation: SurfaceStatusAdapterOperation
        var state: State
        let snapshots: [Snapshot]
    }

    let standardManager: SurfaceStatusAdapterManager
    let codexPresenceManager: SurfaceStatusCodexPresenceManager
    private let homeDirectory: URL
    private let stateDirectory: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        stateDirectory: URL? = nil,
        standardPayloads: [SurfaceStatusAdapterPayload]? = nil,
        codexPresenceLauncherBytes: Data? = nil,
        codexPresenceSnippetBytes: Data? = nil
    ) throws {
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let state = stateDirectory?.standardizedFileURL.resolvingSymlinksInPath()
            ?? home.appending(path: ".local/state/cmux/surface-status-adapters", directoryHint: .isDirectory)
        self.homeDirectory = home
        self.stateDirectory = state
        standardManager = try SurfaceStatusAdapterManager(
            homeDirectory: home,
            stateDirectory: state,
            payloads: standardPayloads
        )
        codexPresenceManager = try SurfaceStatusCodexPresenceManager(
            homeDirectory: home,
            stateDirectory: state,
            launcherBytes: codexPresenceLauncherBytes,
            snippetBytes: codexPresenceSnippetBytes
        )
    }

    private var journalURL: URL { stateDirectory.appending(path: "integration-transaction.json") }
    private var lockURL: URL { stateDirectory.appending(path: "integration-manager.lock") }

    private var snapshotURLs: [String: URL] {
        var result = [
            "standard-receipt": standardManager.receiptURL,
            "codex-launcher": codexPresenceManager.launcherURL,
            "codex-snippet": codexPresenceManager.snippetURL,
            "zshrc": codexPresenceManager.zshrcURL,
            "codex-receipt": codexPresenceManager.receiptURL,
        ]
        for payload in standardManager.payloads {
            result["standard-\(payload.id)"] = standardManager.destination(for: payload)
        }
        return result
    }

    func recoverIncompleteTransaction() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            try standardManager.recoverIncompleteTransaction()
            return
        }
        try prepareStateDirectory()
        try withLock {
            try recoverIntegrationJournalLocked()
            try standardManager.recoverIncompleteTransaction()
        }
    }

    func inspect() throws -> SurfaceStatusManagerInspection {
        let standard = try standardManager.inspect()
        let codex = try codexPresenceManager.inspect()
        return SurfaceStatusManagerInspection(
            adapters: standard.adapters + [
                SurfaceStatusAdapterInspection(id: "codex", state: codex.state, destination: codex.destination),
            ],
            receiptPresent: standard.receiptPresent || FileManager.default.fileExists(atPath: codexPresenceManager.receiptURL.path)
        )
    }

    func apply(_ operation: SurfaceStatusAdapterOperation) throws -> SurfaceStatusManagerInspection {
        try prepareStateDirectory()
        return try withLock {
            try recoverIntegrationJournalLocked()
            try standardManager.recoverIncompleteTransaction()

            let before = try inspect()
            try rejectUnsafeStates(before)
            let standardStates = before.adapters.filter { $0.id != "codex" }.map(\.state)
            let codexState = before.adapters.first { $0.id == "codex" }?.state ?? .notInstalled
            let mutateStandard = shouldMutate(operation, states: standardStates)
            let mutateCodex = shouldMutate(operation, states: [codexState])
            guard mutateStandard || mutateCodex else { return before }

            var journal = Journal(
                schemaVersion: 1,
                transactionID: UUID(),
                operation: operation,
                state: .applying,
                snapshots: try snapshotURLs.sorted(by: { $0.key < $1.key }).map { try snapshot(id: $0.key, url: $0.value) }
            )
            try writeJournal(journal)
            do {
                if mutateStandard { _ = try standardManager.apply(operation) }
                if mutateCodex { _ = try codexPresenceManager.apply(operation) }
                journal.state = .committed
                try writeJournal(journal)
                try FileManager.default.removeItem(at: journalURL)
            } catch {
                let operationError = error
                do {
                    try recoverIntegrationJournalLocked()
                    try standardManager.recoverIncompleteTransaction()
                } catch {
                    // Preserve the durable journal when rollback cannot prove
                    // that current bytes were written by this transaction.
                    throw SurfaceStatusAdapterManagerError.operationFailed(
                        "\(operationError.localizedDescription) Rollback stopped to preserve a concurrent edit: \(error.localizedDescription)"
                    )
                }
                throw operationError
            }
            return try inspect()
        }
    }

    private func shouldMutate(_ operation: SurfaceStatusAdapterOperation, states: [SurfaceStatusAdapterState]) -> Bool {
        switch operation {
        case .install:
            states.contains { $0 == .notInstalled || $0 == .updateAvailable || $0 == .disabled }
        case .disable:
            states.contains { $0 == .enabled || $0 == .updateAvailable }
        case .enable:
            states.contains(.disabled)
        case .uninstall:
            states.contains { $0 != .notInstalled }
        }
    }

    private func rejectUnsafeStates(_ inspection: SurfaceStatusManagerInspection) throws {
        for adapter in inspection.adapters {
            switch adapter.state {
            case .drifted:
                throw SurfaceStatusAdapterManagerError.modifiedDestination(adapter.destination)
            case .unmanaged:
                throw SurfaceStatusAdapterManagerError.unmanagedDestination(adapter.destination)
            default:
                continue
            }
        }
    }

    private func prepareStateDirectory() throws {
        guard stateDirectory.pathComponents.count > homeDirectory.pathComponents.count,
              stateDirectory.pathComponents.starts(with: homeDirectory.pathComponents),
              !hasSymlinkComponent(stateDirectory) else {
            throw SurfaceStatusAdapterManagerError.unsafePath(stateDirectory)
        }
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: stateDirectory.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw SurfaceStatusAdapterManagerError.unsafePath(stateDirectory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw SurfaceStatusAdapterManagerError.operationFailed(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == getuid(),
              fchmod(descriptor, 0o600) == 0 else {
            throw SurfaceStatusAdapterManagerError.unsafePath(lockURL)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SurfaceStatusAdapterManagerError.operationFailed(String(cString: strerror(errno)))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func snapshot(id: String, url: URL) throws -> Journal.Snapshot {
        guard snapshotURLs[id]?.standardizedFileURL == url.standardizedFileURL else {
            throw SurfaceStatusAdapterManagerError.unsafePath(url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .init(id: id, existed: false, data: nil, permissions: nil)
        }
        let data = try boundedRegularFileData(at: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return .init(
            id: id,
            existed: true,
            data: data,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue
        )
    }

    private func writeJournal(_ journal: Journal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(encoder.encode(journal), to: journalURL, permissions: 0o600)
    }

    private func recoverIntegrationJournalLocked() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let journal: Journal
        do {
            journal = try JSONDecoder().decode(Journal.self, from: boundedRegularFileData(at: journalURL))
        } catch {
            throw SurfaceStatusAdapterManagerError.operationFailed("Invalid integration recovery journal")
        }
        let allowedIDs = Set(snapshotURLs.keys)
        guard journal.schemaVersion == 1,
              Set(journal.snapshots.map(\.id)) == allowedIDs,
              journal.snapshots.count == allowedIDs.count else {
            throw SurfaceStatusAdapterManagerError.operationFailed("Unsafe integration recovery journal")
        }
        if journal.state == .committed {
            try FileManager.default.removeItem(at: journalURL)
            return
        }
        for snapshot in journal.snapshots.reversed() {
            try restore(snapshot, operation: journal.operation)
        }
        try FileManager.default.removeItem(at: journalURL)
    }

    private func restore(_ snapshot: Journal.Snapshot, operation: SurfaceStatusAdapterOperation) throws {
        guard let url = snapshotURLs[snapshot.id] else {
            throw SurfaceStatusAdapterManagerError.operationFailed("Unsafe integration recovery target")
        }
        let current = try optionalRegularFileData(at: url)
        if current == snapshot.data { return }
        guard managerMayHaveWritten(current, snapshot: snapshot, operation: operation) else {
            throw SurfaceStatusAdapterManagerError.modifiedDestination(url)
        }
        if snapshot.existed {
            guard let data = snapshot.data else {
                throw SurfaceStatusAdapterManagerError.operationFailed("Missing integration recovery data")
            }
            try atomicWrite(data, to: url, permissions: snapshot.permissions ?? 0o600)
        } else if current != nil {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func managerMayHaveWritten(
        _ current: Data?,
        snapshot: Journal.Snapshot,
        operation: SurfaceStatusAdapterOperation
    ) -> Bool {
        if snapshot.id.hasPrefix("standard-") && snapshot.id != "standard-receipt" {
            let id = String(snapshot.id.dropFirst("standard-".count))
            guard let payload = standardManager.payloads.first(where: { $0.id == id }) else { return false }
            return current == nil || current == payload.bytes
        }
        switch snapshot.id {
        case "codex-launcher":
            return current == nil || current == codexPresenceManager.launcherBytes
        case "codex-snippet":
            return current == nil || current == codexPresenceManager.snippetBytes
        case "zshrc":
            return current == expectedZshrcMutation(from: snapshot.data, operation: operation)
        case "standard-receipt":
            return current == nil || current.map(isValidStandardReceipt) == true
        case "codex-receipt":
            return current == nil || current.map(isValidCodexReceipt) == true
        default:
            return false
        }
    }

    private func expectedZshrcMutation(from original: Data?, operation: SurfaceStatusAdapterOperation) -> Data? {
        let originalText = original.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        switch operation {
        case .install, .enable:
            guard !originalText.contains(SurfaceStatusCodexPresenceManager.sourceBlock) else { return original }
            return Data((originalText + SurfaceStatusCodexPresenceManager.sourceBlock).utf8)
        case .disable, .uninstall:
            guard let range = originalText.range(of: SurfaceStatusCodexPresenceManager.sourceBlock) else { return original }
            let rewritten = originalText.replacingCharacters(in: range, with: "")
            return rewritten.isEmpty ? nil : Data(rewritten.utf8)
        }
    }

    private func isValidStandardReceipt(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let receipt = try? decoder.decode(SurfaceStatusAdapterReceipt.self, from: data),
              receipt.schemaVersion == SurfaceStatusAdapterManager.receiptSchemaVersion,
              Set(receipt.records.map(\.id)).count == receipt.records.count else { return false }
        return receipt.records.allSatisfy { record in
            standardManager.payloads.contains { payload in
                payload.id == record.id && payload.sha256 == record.sha256
            }
        }
    }

    private func isValidCodexReceipt(_ data: Data) -> Bool {
        guard let receipt = try? JSONDecoder().decode(SurfaceStatusCodexPresenceManager.Receipt.self, from: data) else {
            return false
        }
        return receipt.schemaVersion == 1
            && receipt.launcherSHA256 == sha256(codexPresenceManager.launcherBytes)
            && receipt.snippetSHA256 == sha256(codexPresenceManager.snippetBytes)
    }

    private func optionalRegularFileData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try boundedRegularFileData(at: url)
    }

    private func boundedRegularFileData(at url: URL) throws -> Data {
        guard !hasSymlinkComponent(url) else { throw SurfaceStatusAdapterManagerError.unsafePath(url) }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SurfaceStatusAdapterManagerError.unsafePath(url) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == getuid(),
              info.st_size >= 0,
              info.st_size <= 1_048_576 else {
            throw SurfaceStatusAdapterManagerError.unsafePath(url)
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        guard data.count == info.st_size else { throw SurfaceStatusAdapterManagerError.unsafePath(url) }
        return data
    }

    private func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        let parent = url.deletingLastPathComponent()
        guard parent.pathComponents.starts(with: homeDirectory.pathComponents),
              !hasSymlinkComponent(parent) else {
            throw SurfaceStatusAdapterManagerError.unsafePath(url)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func hasSymlinkComponent(_ url: URL) -> Bool {
        let root = homeDirectory.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: root) else { return true }
        var current = homeDirectory
        for component in components.dropFirst(root.count) {
            current.append(path: component)
            var info = stat()
            if lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
