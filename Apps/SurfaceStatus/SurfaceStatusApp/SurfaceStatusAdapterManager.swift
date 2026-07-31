import CryptoKit
import Foundation

struct SurfaceStatusAdapterPayload: Sendable {
    let id: String
    let resourceName: String
    let resourceExtension: String
    let destinationComponents: [String]
    let bytes: Data

    var sha256: String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

enum SurfaceStatusAdapterState: String, Codable, Sendable {
    case notInstalled
    case enabled
    case updateAvailable
    case disabled
    case drifted
    case unmanaged
}

struct SurfaceStatusAdapterInspection: Identifiable, Sendable {
    let id: String
    let state: SurfaceStatusAdapterState
    let destination: URL
}

struct SurfaceStatusManagerInspection: Sendable {
    let adapters: [SurfaceStatusAdapterInspection]
    let receiptPresent: Bool
}

enum SurfaceStatusAdapterOperation: String, Codable, Equatable, Sendable {
    case install
    case disable
    case enable
    case uninstall
}

enum SurfaceStatusAdapterManagerError: LocalizedError {
    case invalidBundledPayload(String)
    case invalidReceipt
    case unmanagedDestination(URL)
    case modifiedDestination(URL)
    case unsafePath(URL)
    case noInstallation
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidBundledPayload(id):
            String(localized: "manager.error.invalidPayload", defaultValue: "The bundled adapter for \(id) is invalid.")
        case .invalidReceipt:
            String(localized: "manager.error.invalidReceipt", defaultValue: "The installation receipt is invalid. No files were changed.")
        case let .unmanagedDestination(url):
            String(localized: "manager.error.unmanagedDestination", defaultValue: "An unmanaged file already exists at \(url.path).")
        case let .modifiedDestination(url):
            String(localized: "manager.error.modifiedDestination", defaultValue: "The installed adapter at \(url.path) was modified and was preserved.")
        case let .unsafePath(url):
            String(localized: "manager.error.unsafePath", defaultValue: "The adapter path is unsafe: \(url.path).")
        case .noInstallation:
            String(localized: "manager.error.noInstallation", defaultValue: "No managed adapter installation was found.")
        case let .operationFailed(message):
            String(localized: "manager.error.operationFailed", defaultValue: "The operation failed and was rolled back: \(message)")
        }
    }
}

private struct SurfaceStatusTransactionJournal: Codable, Sendable {
    struct Snapshot: Codable, Sendable {
        var id: String
        var existed: Bool
        var data: Data?
        var permissions: Int?
    }

    var schemaVersion: Int
    var transactionID: UUID
    var snapshots: [Snapshot]
}

struct SurfaceStatusAdapterReceipt: Codable, Sendable {
    struct Record: Codable, Sendable {
        var id: String
        var sha256: String
        var enabled: Bool
        var payloadVersion: Int
    }

    var schemaVersion: Int
    var installationID: UUID
    var createdAt: Date
    var updatedAt: Date
    var records: [Record]
}

struct SurfaceStatusAdapterManager: Sendable {
    static let receiptSchemaVersion = 1
    static let payloadVersion = 1

    let homeDirectory: URL
    let stateDirectory: URL
    let payloads: [SurfaceStatusAdapterPayload]
    private var fileManager: FileManager { .default }

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        stateDirectory: URL? = nil,
        payloads: [SurfaceStatusAdapterPayload]? = nil
    ) throws {
        self.homeDirectory = homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.stateDirectory = stateDirectory?.standardizedFileURL.resolvingSymlinksInPath()
            ?? self.homeDirectory.appending(path: ".local/state/cmux/surface-status-adapters", directoryHint: .isDirectory)
        self.payloads = try payloads ?? Self.bundledPayloads()
        guard Set(self.payloads.map(\.id)).count == self.payloads.count,
              self.payloads.allSatisfy({ !$0.bytes.isEmpty }) else {
            throw SurfaceStatusAdapterManagerError.invalidBundledPayload("unknown")
        }
    }

    static func bundledPayloads(bundle: Bundle = .main) throws -> [SurfaceStatusAdapterPayload] {
        try [
            loadPayload(
                id: "pi",
                resourceName: "pi-sidebar-agent-status",
                resourceExtension: "txt",
                destinationComponents: [".pi", "agent", "extensions", "cmux-sidebar-agent-status.ts"],
                bundle: bundle
            ),
            loadPayload(
                id: "opencode",
                resourceName: "opencode-sidebar-agent-status",
                resourceExtension: "mjs",
                destinationComponents: [".config", "opencode", "plugins", "cmux-sidebar-agent-status.js"],
                bundle: bundle
            ),
        ]
    }

    private static func loadPayload(
        id: String,
        resourceName: String,
        resourceExtension: String,
        destinationComponents: [String],
        bundle: Bundle
    ) throws -> SurfaceStatusAdapterPayload {
        let url = bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: "AdapterPayloads"
        ) ?? bundle.url(forResource: resourceName, withExtension: resourceExtension)
        guard let url, let bytes = try? Data(contentsOf: url), !bytes.isEmpty else {
            throw SurfaceStatusAdapterManagerError.invalidBundledPayload(id)
        }
        return SurfaceStatusAdapterPayload(
            id: id,
            resourceName: resourceName,
            resourceExtension: resourceExtension,
            destinationComponents: destinationComponents,
            bytes: bytes
        )
    }

    var receiptURL: URL {
        stateDirectory.appending(path: "receipt.json", directoryHint: .notDirectory)
    }

    private var journalURL: URL {
        stateDirectory.appending(path: "transaction.json", directoryHint: .notDirectory)
    }

    func destination(for payload: SurfaceStatusAdapterPayload) -> URL {
        payload.destinationComponents.reduce(homeDirectory) { partial, component in
            partial.appending(path: component)
        }
    }

    func recoverIncompleteTransaction() throws {
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        try validateStateDirectoryBoundary()
        try fileManager.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try withExclusiveLock { try recoverIncompleteTransactionLocked() }
    }

    private func recoverIncompleteTransactionLocked() throws {
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        let journal: SurfaceStatusTransactionJournal
        do {
            journal = try JSONDecoder().decode(
                SurfaceStatusTransactionJournal.self,
                from: boundedRegularFileData(at: journalURL)
            )
        } catch {
            throw SurfaceStatusAdapterManagerError.operationFailed("Invalid recovery journal")
        }
        guard journal.schemaVersion == 1,
              Set(journal.snapshots.map(\.id)).count == journal.snapshots.count,
              journal.snapshots.allSatisfy({ allowedSnapshotIDs.contains($0.id) }) else {
            throw SurfaceStatusAdapterManagerError.operationFailed("Unsafe recovery journal")
        }
        for snapshot in journal.snapshots.reversed() {
            try restoreJournalSnapshot(snapshot)
        }
        try fileManager.removeItem(at: journalURL)
    }

    func inspect() throws -> SurfaceStatusManagerInspection {
        let receipt = try loadReceipt()
        let records = Dictionary(uniqueKeysWithValues: (receipt?.records ?? []).map { ($0.id, $0) })
        let inspections = try payloads.map { payload in
            let destination = destination(for: payload)
            let currentHash = try regularFileHash(at: destination)
            let record = records[payload.id]
            let state: SurfaceStatusAdapterState
            if let record {
                if record.enabled {
                    state = currentHash == record.sha256
                        ? (record.sha256 == payload.sha256 ? .enabled : .updateAvailable)
                        : .drifted
                } else {
                    state = currentHash == nil ? .disabled : .drifted
                }
            } else {
                state = currentHash == nil ? .notInstalled : .unmanaged
            }
            return SurfaceStatusAdapterInspection(id: payload.id, state: state, destination: destination)
        }
        return SurfaceStatusManagerInspection(
            adapters: inspections,
            receiptPresent: receipt != nil
        )
    }

    func apply(_ operation: SurfaceStatusAdapterOperation) throws -> SurfaceStatusManagerInspection {
        try validateStateDirectoryBoundary()
        try fileManager.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try withExclusiveLock {
            try recoverIncompleteTransactionLocked()
            let lockedReceipt = try loadReceipt()
            if operation != .install, lockedReceipt == nil {
                throw SurfaceStatusAdapterManagerError.noInstallation
            }
            var receipt = lockedReceipt ?? SurfaceStatusAdapterReceipt(
                schemaVersion: Self.receiptSchemaVersion,
                installationID: UUID(),
                createdAt: Date(),
                updatedAt: Date(),
                records: []
            )
            for payload in payloads {
                try validateDestination(destination(for: payload), payload: payload)
            }
            let snapshots = try [snapshot(receiptURL)] + payloads.map { try snapshot(destination(for: $0)) }
            try writeJournal(snapshots)

            do {
                var records = Dictionary(uniqueKeysWithValues: receipt.records.map { ($0.id, $0) })
                for payload in payloads {
                    let destination = destination(for: payload)
                    try validateDestination(destination, payload: payload)
                    let currentHash = try regularFileHash(at: destination)
                    let record = records[payload.id]
                    switch operation {
                    case .install:
                        if var record {
                            if record.enabled {
                                guard currentHash == record.sha256 else {
                                    throw SurfaceStatusAdapterManagerError.modifiedDestination(destination)
                                }
                            } else {
                                guard currentHash == nil else {
                                    throw SurfaceStatusAdapterManagerError.unmanagedDestination(destination)
                                }
                            }
                            if !record.enabled || record.sha256 != payload.sha256 || record.payloadVersion != Self.payloadVersion {
                                try atomicWrite(payload.bytes, to: destination, permissions: 0o644)
                                record.sha256 = payload.sha256
                                record.payloadVersion = Self.payloadVersion
                                record.enabled = true
                                records[payload.id] = record
                            }
                            continue
                        }
                        guard currentHash == nil else {
                            throw SurfaceStatusAdapterManagerError.unmanagedDestination(destination)
                        }
                        try atomicWrite(payload.bytes, to: destination, permissions: 0o644)
                        records[payload.id] = .init(
                            id: payload.id,
                            sha256: payload.sha256,
                            enabled: true,
                            payloadVersion: Self.payloadVersion
                        )
                    case .disable:
                        guard var record else { continue }
                        if let currentHash, currentHash != record.sha256 {
                            throw SurfaceStatusAdapterManagerError.modifiedDestination(destination)
                        }
                        if currentHash != nil { try fileManager.removeItem(at: destination) }
                        record.enabled = false
                        records[payload.id] = record
                    case .enable:
                        guard var record else { continue }
                        guard currentHash == nil else {
                            if currentHash == record.sha256, record.enabled { continue }
                            throw SurfaceStatusAdapterManagerError.unmanagedDestination(destination)
                        }
                        try atomicWrite(payload.bytes, to: destination, permissions: 0o644)
                        record.sha256 = payload.sha256
                        record.payloadVersion = Self.payloadVersion
                        record.enabled = true
                        records[payload.id] = record
                    case .uninstall:
                        guard let record else { continue }
                        if let currentHash, currentHash != record.sha256 {
                            throw SurfaceStatusAdapterManagerError.modifiedDestination(destination)
                        }
                        if currentHash != nil { try fileManager.removeItem(at: destination) }
                        records.removeValue(forKey: payload.id)
                    }
                }
                receipt.records = payloads.compactMap { records[$0.id] }
                receipt.updatedAt = Date()
                if operation == .uninstall, receipt.records.isEmpty {
                    if fileManager.fileExists(atPath: receiptURL.path) {
                        try fileManager.removeItem(at: receiptURL)
                    }
                } else {
                    try writeReceipt(receipt)
                }
                if fileManager.fileExists(atPath: journalURL.path) {
                    try fileManager.removeItem(at: journalURL)
                }
            } catch {
                do {
                    for snapshot in snapshots.reversed() {
                        try restore(snapshot)
                    }
                } catch {
                    throw SurfaceStatusAdapterManagerError.operationFailed(error.localizedDescription)
                }
                try? fileManager.removeItem(at: journalURL)
                throw error
            }
        }
        return try inspect()
    }

    private func loadReceipt() throws -> SurfaceStatusAdapterReceipt? {
        guard fileManager.fileExists(atPath: receiptURL.path) else { return nil }
        try validateStateDirectoryBoundary()
        let data = try boundedRegularFileData(at: receiptURL)
        let receipt: SurfaceStatusAdapterReceipt
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            receipt = try decoder.decode(SurfaceStatusAdapterReceipt.self, from: data)
        } catch {
            throw SurfaceStatusAdapterManagerError.invalidReceipt
        }
        guard receipt.schemaVersion == Self.receiptSchemaVersion,
              Set(receipt.records.map(\.id)).count == receipt.records.count,
              receipt.records.allSatisfy({ record in
                  payloads.contains { payload in payload.id == record.id }
                      && record.sha256.count == 64
                      && record.sha256.allSatisfy(\.isHexDigit)
                      && record.payloadVersion > 0
              }) else {
            throw SurfaceStatusAdapterManagerError.invalidReceipt
        }
        return receipt
    }

    private func writeReceipt(_ receipt: SurfaceStatusAdapterReceipt) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(encoder.encode(receipt) + Data("\n".utf8), to: receiptURL, permissions: 0o600)
    }

    private func validateStateDirectoryBoundary() throws {
        guard isDescendant(stateDirectory, of: homeDirectory),
              !hasSymbolicLinkComponent(stateDirectory) else {
            throw SurfaceStatusAdapterManagerError.unsafePath(stateDirectory)
        }
    }

    private func validateDestination(_ url: URL, payload: SurfaceStatusAdapterPayload) throws {
        guard url.standardizedFileURL == destination(for: payload).standardizedFileURL,
              isDescendant(url, of: homeDirectory),
              !hasSymbolicLinkComponent(url) else {
            throw SurfaceStatusAdapterManagerError.unsafePath(url)
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw SurfaceStatusAdapterManagerError.unsafePath(url)
            }
        }
    }

    private func regularFileHash(at url: URL) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return SHA256.hash(data: try boundedRegularFileData(at: url))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func boundedRegularFileData(at url: URL) throws -> Data {
        guard !hasSymbolicLinkComponent(url) else { throw SurfaceStatusAdapterManagerError.unsafePath(url) }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SurfaceStatusAdapterManagerError.unsafePath(url) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= 1_048_576 else {
            throw SurfaceStatusAdapterManagerError.unsafePath(url)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count == info.st_size else { throw SurfaceStatusAdapterManagerError.unsafePath(url) }
        return data
    }

    private func atomicWrite(_ data: Data, to destination: URL, permissions: Int) throws {
        let parent = destination.deletingLastPathComponent()
        guard (parent.standardizedFileURL == homeDirectory.standardizedFileURL || isDescendant(parent, of: homeDirectory)),
              !hasSymbolicLinkComponent(parent) else {
            throw SurfaceStatusAdapterManagerError.unsafePath(destination)
        }
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = parent.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = stateDirectory.appending(path: "manager.lock")
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

    private var allowedSnapshotURLs: [String: URL] {
        var result = ["receipt": receiptURL]
        for payload in payloads { result[payload.id] = destination(for: payload) }
        return result
    }

    private var allowedSnapshotIDs: Set<String> { Set(allowedSnapshotURLs.keys) }

    private func snapshot(_ url: URL) throws -> (URL, Data?, NSNumber?) {
        guard allowedSnapshotURLs.values.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else {
            throw SurfaceStatusAdapterManagerError.unsafePath(url)
        }
        guard fileManager.fileExists(atPath: url.path) else { return (url, nil, nil) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_048_576 else {
            throw SurfaceStatusAdapterManagerError.unsafePath(url)
        }
        let data = try boundedRegularFileData(at: url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (url, data, attributes[.posixPermissions] as? NSNumber)
    }

    private func writeJournal(_ snapshots: [(URL, Data?, NSNumber?)]) throws {
        let idsByPath = Dictionary(uniqueKeysWithValues: allowedSnapshotURLs.map { ($0.value.standardizedFileURL, $0.key) })
        let journal = SurfaceStatusTransactionJournal(
            schemaVersion: 1,
            transactionID: UUID(),
            snapshots: try snapshots.map { url, data, permissions in
                guard let id = idsByPath[url.standardizedFileURL] else {
                    throw SurfaceStatusAdapterManagerError.unsafePath(url)
                }
                return .init(
                    id: id,
                    existed: data != nil,
                    data: data,
                    permissions: permissions?.intValue
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try atomicWrite(encoder.encode(journal), to: journalURL, permissions: 0o600)
    }

    private func restoreJournalSnapshot(_ snapshot: SurfaceStatusTransactionJournal.Snapshot) throws {
        guard let url = allowedSnapshotURLs[snapshot.id] else {
            throw SurfaceStatusAdapterManagerError.operationFailed("Unsafe recovery target")
        }
        let current = try regularFileHash(at: url)
        let original = snapshot.data.map(Self.sha256Hex)
        if current == original { return }

        // Recovery may touch a changed path only when its current bytes are a
        // state this app itself can write. Anything else may have been created
        // by the user after the crash and is preserved fail-closed.
        guard try isManagerWrittenRecoveryState(id: snapshot.id, at: url, currentHash: current) else {
            throw SurfaceStatusAdapterManagerError.modifiedDestination(url)
        }
        if snapshot.existed {
            guard let data = snapshot.data else {
                throw SurfaceStatusAdapterManagerError.operationFailed("Missing recovery data")
            }
            try atomicWrite(data, to: url, permissions: snapshot.permissions ?? 0o600)
        } else if current != nil {
            try fileManager.removeItem(at: url)
        }
    }

    private func isManagerWrittenRecoveryState(id: String, at url: URL, currentHash: String?) throws -> Bool {
        guard let currentHash else { return true }
        if let payload = payloads.first(where: { $0.id == id }) {
            return currentHash == payload.sha256
        }
        guard id == "receipt" else { return false }
        guard let receipt = try? loadReceipt(), !receipt.records.isEmpty else { return false }
        return receipt.records.allSatisfy { record in
            payloads.contains { $0.id == record.id && $0.sha256 == record.sha256 }
        }
    }

    private func restore(_ snapshot: (URL, Data?, NSNumber?)) throws {
        let (url, data, permissions) = snapshot
        if let data {
            try atomicWrite(data, to: url, permissions: permissions?.intValue ?? 0o600)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.pathComponents
        let rootPath = root.standardizedFileURL.pathComponents
        return candidatePath.count > rootPath.count && candidatePath.starts(with: rootPath)
    }

    private func hasSymbolicLinkComponent(_ url: URL) -> Bool {
        let rootComponents = homeDirectory.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return true }
        var current = homeDirectory
        for component in components.dropFirst(rootComponents.count) {
            current.append(path: component)
            var info = stat()
            if lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                return true
            }
        }
        return false
    }
}

private extension Data {
    static func + (left: Data, right: Data) -> Data {
        var result = left
        result.append(right)
        return result
    }
}
