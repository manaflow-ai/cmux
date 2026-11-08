import Foundation

/// Persists the authorization that camera injection temporarily replaces.
///
/// Worker crashes cannot erase this record, so the host's durable Simulator
/// cleanup can restore the prior TCC state after relaunching the target app.
public struct SimulatorCameraAuthorizationStore: Sendable {
    private let directory: URL?
    private let legacyDirectory: URL?
    private let journalMutationGate: SimulatorMutationGate

    /// Creates a store in durable per-user Application Support by default.
    public init(
        directory: URL? = nil,
        legacyDirectory: URL? = nil,
        fileManager: FileManager = FileManager()
    ) {
        self.init(
            directory: directory,
            legacyDirectory: legacyDirectory,
            fileManager: fileManager,
            journalMutationGate: SimulatorMutationGate()
        )
    }

    package init(
        directory: URL?,
        legacyDirectory: URL? = nil,
        fileManager: FileManager = FileManager(),
        journalMutationGate: SimulatorMutationGate
    ) {
        if let directory {
            let pathsMatch = legacyDirectory.map {
                $0.standardizedFileURL.path == directory.standardizedFileURL.path
            } ?? false
            self.directory = directory
            self.legacyDirectory = pathsMatch ? nil : legacyDirectory
        } else {
            let directory = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
                .appendingPathComponent("com.cmux.simulator-ownership", isDirectory: true)
                .appendingPathComponent("camera-authorizations", isDirectory: true)
            let legacyDirectory = legacyDirectory ?? fileManager.temporaryDirectory
                .appendingPathComponent("com.cmux.simulator-ownership", isDirectory: true)
                .appendingPathComponent("camera-authorizations", isDirectory: true)
            let pathsMatch = directory.map {
                legacyDirectory.standardizedFileURL.path
                    == $0.standardizedFileURL.path
            } ?? false
            self.directory = directory
            self.legacyDirectory = pathsMatch ? nil : legacyDirectory
        }
        self.journalMutationGate = journalMutationGate
    }

    package func save(
        _ authorization: SimulatorPrivacyAuthorization,
        deviceIdentifier: String,
        bundleIdentifier: String,
        ownerProcessIdentity: SimulatorProcessIdentity? = .parent
    ) async throws {
        guard [.notDetermined, .denied, .granted].contains(authorization),
              let ownerProcessIdentity else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileName = journalFileName(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        try await withJournalLock(fileName: fileName) {
            let existing: SimulatorCameraAuthorizationRecord?
            switch try reconcileLocked(fileName: fileName) {
            case let .available(record):
                existing = record
            case .liveLegacyOwner:
                throw CocoaError(.fileWriteFileExists)
            }
            try writeDurableRecord(
                SimulatorCameraAuthorizationRecord(
                    deviceIdentifier: deviceIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    authorization: existing?.authorization ?? authorization,
                    ownerProcessIdentity: ownerProcessIdentity
                ),
                fileName: fileName,
                fileManager: FileManager()
            )
        }
    }

    package func authorization(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) async throws -> SimulatorPrivacyAuthorization? {
        try await record(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )?.authorization
    }

    package func record(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) async throws -> SimulatorCameraAuthorizationRecord? {
        let fileName = journalFileName(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        return try await withJournalLock(fileName: fileName) {
            switch try reconcileLocked(fileName: fileName) {
            case let .available(record):
                return record
            case .liveLegacyOwner:
                return nil
            }
        }
    }

    package func records() async throws -> (
        records: [SimulatorCameraAuthorizationRecord],
        hadFailures: Bool
    ) {
        let fileNames = try candidateFileNames(fileManager: FileManager())
        var records: [SimulatorCameraAuthorizationRecord] = []
        var hadFailures = false
        for fileName in fileNames.sorted() {
            do {
                let outcome = try await withJournalLock(fileName: fileName) {
                    try reconcileLocked(fileName: fileName)
                }
                if case let .available(record?) = outcome {
                    records.append(record)
                }
            } catch {
                hadFailures = true
            }
        }
        return (records, hadFailures)
    }

    package func remove(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) async throws {
        let fileName = journalFileName(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        try await withJournalLock(fileName: fileName) {
            guard case .available(.some) = try reconcileLocked(fileName: fileName) else {
                return
            }
            try removeIfPresent(
                try durableURL(fileName: fileName),
                fileManager: FileManager()
            )
        }
    }

    private func withJournalLock<Result: Sendable>(
        fileName: String,
        operation: () throws -> Result
    ) async throws -> Result {
        try await journalMutationGate.withLocks([
            SimulatorMutationKey(
                value: "camera-authorization-journal\0\(fileName)"
            ),
        ]) {
            try operation()
        }
    }

    private func reconcileLocked(fileName: String) throws -> ReconciliationOutcome {
        let fileManager = FileManager()
        let durableURL = try durableURL(fileName: fileName)
        let legacyURL = legacyURL(fileName: fileName)
        let markerURL = try markerURL(fileName: fileName)
        let marker = try loadMarker(
            at: markerURL,
            fileName: fileName,
            fileManager: fileManager
        )
        if marker?.phase == .corruptionBlocked {
            let legacyExists = legacyURL.map {
                fileManager.fileExists(atPath: $0.path)
            } ?? false
            let durableExists = fileManager.fileExists(atPath: durableURL.path)
            guard !legacyExists, !durableExists else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try removeIfPresent(markerURL, fileManager: fileManager)
            return .available(nil)
        }

        let legacyRecord: SimulatorCameraAuthorizationRecord?
        if let legacyURL, fileManager.fileExists(atPath: legacyURL.path) {
            do {
                legacyRecord = try loadLegacyRecord(
                    at: legacyURL,
                    fileName: fileName
                )
            } catch {
                try persistCorruptionBlock(
                    at: markerURL,
                    legacyRecord: nil,
                    durableRecord: marker?.durableRecord,
                    fileManager: fileManager
                )
                _ = quarantine(
                    legacyURL,
                    rootDirectory: legacyURL.deletingLastPathComponent(),
                    fileManager: fileManager
                )
                throw error
            }
        } else {
            legacyRecord = nil
        }

        let durableRecord: SimulatorCameraAuthorizationRecord?
        if fileManager.fileExists(atPath: durableURL.path) {
            do {
                durableRecord = try loadDurableRecord(
                    at: durableURL,
                    fileName: fileName
                )
            } catch {
                try persistCorruptionBlock(
                    at: markerURL,
                    legacyRecord: legacyRecord,
                    durableRecord: nil,
                    fileManager: fileManager
                )
                _ = quarantine(
                    durableURL,
                    rootDirectory: try requiredDirectory(),
                    fileManager: fileManager
                )
                throw error
            }
        } else {
            durableRecord = nil
        }

        if let marker {
            return try resolve(
                marker: marker,
                legacyRecord: legacyRecord,
                durableRecord: durableRecord,
                legacyURL: legacyURL,
                durableURL: durableURL,
                markerURL: markerURL,
                fileManager: fileManager
            )
        }

        switch (legacyRecord, durableRecord) {
        case let (legacyRecord?, durableRecord?):
            let marker = ReconciliationMarker(
                phase: .suppressingLegacy,
                legacyRecord: legacyRecord,
                durableRecord: durableRecord
            )
            try writeMarker(marker, to: markerURL, fileManager: fileManager)
            return try resolveDuplicate(
                marker: marker,
                legacyRecord: legacyRecord,
                durableRecord: durableRecord,
                legacyURL: legacyURL,
                durableURL: durableURL,
                markerURL: markerURL,
                fileManager: fileManager
            )
        case let (legacyRecord?, nil):
            guard !legacyRecord.isOwnedByRunningProcess else {
                return .liveLegacyOwner
            }
            try writeDurableRecord(
                legacyRecord,
                fileName: fileName,
                fileManager: fileManager
            )
            try writeMarker(
                ReconciliationMarker(
                    phase: .migratedLegacy,
                    legacyRecord: legacyRecord,
                    durableRecord: nil
                ),
                to: markerURL,
                fileManager: fileManager
            )
            if let legacyURL {
                try removeIfPresent(legacyURL, fileManager: fileManager)
            }
            try removeIfPresent(markerURL, fileManager: fileManager)
            return .available(legacyRecord)
        case let (nil, durableRecord?):
            return .available(durableRecord)
        case (nil, nil):
            return .available(nil)
        }
    }

    private func resolve(
        marker: ReconciliationMarker,
        legacyRecord: SimulatorCameraAuthorizationRecord?,
        durableRecord: SimulatorCameraAuthorizationRecord?,
        legacyURL: URL?,
        durableURL: URL,
        markerURL: URL,
        fileManager: FileManager
    ) throws -> ReconciliationOutcome {
        switch marker.phase {
        case .suppressingLegacy:
            guard let expectedLegacy = marker.legacyRecord,
                  let expectedDurable = marker.durableRecord else {
                return try blockInconsistentReconciliation(
                    markerURL: markerURL,
                    legacyRecord: legacyRecord,
                    durableRecord: durableRecord,
                    fileManager: fileManager
                )
            }
            guard let legacyRecord else {
                if durableRecord == expectedLegacy {
                    try removeIfPresent(markerURL, fileManager: fileManager)
                    return .available(durableRecord)
                }
                guard durableRecord == nil || durableRecord == expectedDurable else {
                    return try blockInconsistentReconciliation(
                        markerURL: markerURL,
                        legacyRecord: nil,
                        durableRecord: durableRecord,
                        fileManager: fileManager
                    )
                }
                try removeIfPresent(durableURL, fileManager: fileManager)
                try removeIfPresent(markerURL, fileManager: fileManager)
                return .available(nil)
            }
            guard legacyRecord == expectedLegacy else {
                return try blockInconsistentReconciliation(
                    markerURL: markerURL,
                    legacyRecord: legacyRecord,
                    durableRecord: durableRecord,
                    fileManager: fileManager
                )
            }
            if durableRecord == expectedLegacy,
               !legacyRecord.isOwnedByRunningProcess {
                try writeMarker(
                    ReconciliationMarker(
                        phase: .migratedLegacy,
                        legacyRecord: legacyRecord,
                        durableRecord: expectedDurable
                    ),
                    to: markerURL,
                    fileManager: fileManager
                )
                if let legacyURL {
                    try removeIfPresent(legacyURL, fileManager: fileManager)
                }
                try removeIfPresent(markerURL, fileManager: fileManager)
                return .available(legacyRecord)
            }
            guard let durableRecord, durableRecord == expectedDurable else {
                return try blockInconsistentReconciliation(
                    markerURL: markerURL,
                    legacyRecord: legacyRecord,
                    durableRecord: durableRecord,
                    fileManager: fileManager
                )
            }
            return try resolveDuplicate(
                marker: marker,
                legacyRecord: legacyRecord,
                durableRecord: durableRecord,
                legacyURL: legacyURL,
                durableURL: durableURL,
                markerURL: markerURL,
                fileManager: fileManager
            )
        case .migratedLegacy:
            guard let expected = marker.legacyRecord,
                  durableRecord == expected,
                  legacyRecord == nil || legacyRecord == expected else {
                return try blockInconsistentReconciliation(
                    markerURL: markerURL,
                    legacyRecord: legacyRecord,
                    durableRecord: durableRecord,
                    fileManager: fileManager
                )
            }
            if let legacyURL {
                try removeIfPresent(legacyURL, fileManager: fileManager)
            }
            try removeIfPresent(markerURL, fileManager: fileManager)
            return .available(expected)
        case .preservingDurable:
            guard let expected = marker.durableRecord,
                  durableRecord == expected,
                  legacyRecord == nil || legacyRecord == marker.legacyRecord else {
                return try blockInconsistentReconciliation(
                    markerURL: markerURL,
                    legacyRecord: legacyRecord,
                    durableRecord: durableRecord,
                    fileManager: fileManager
                )
            }
            if let legacyURL {
                try removeIfPresent(legacyURL, fileManager: fileManager)
            }
            try removeIfPresent(markerURL, fileManager: fileManager)
            return .available(expected)
        case .corruptionBlocked:
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func resolveDuplicate(
        marker: ReconciliationMarker,
        legacyRecord: SimulatorCameraAuthorizationRecord,
        durableRecord: SimulatorCameraAuthorizationRecord,
        legacyURL: URL?,
        durableURL: URL,
        markerURL: URL,
        fileManager: FileManager
    ) throws -> ReconciliationOutcome {
        if legacyRecord.isOwnedByRunningProcess {
            guard !durableRecord.isOwnedByRunningProcess else {
                return try blockInconsistentReconciliation(
                    markerURL: markerURL,
                    legacyRecord: legacyRecord,
                    durableRecord: durableRecord,
                    fileManager: fileManager
                )
            }
            return .liveLegacyOwner
        }
        if durableRecord.isOwnedByRunningProcess {
            try writeMarker(
                ReconciliationMarker(
                    phase: .preservingDurable,
                    legacyRecord: legacyRecord,
                    durableRecord: durableRecord
                ),
                to: markerURL,
                fileManager: fileManager
            )
            if let legacyURL {
                try removeIfPresent(legacyURL, fileManager: fileManager)
            }
            try removeIfPresent(markerURL, fileManager: fileManager)
            return .available(durableRecord)
        }

        try writeDurableRecord(
            legacyRecord,
            fileName: durableURL.lastPathComponent,
            fileManager: fileManager
        )
        try writeMarker(
            ReconciliationMarker(
                phase: .migratedLegacy,
                legacyRecord: legacyRecord,
                durableRecord: marker.durableRecord
            ),
            to: markerURL,
            fileManager: fileManager
        )
        if let legacyURL {
            try removeIfPresent(legacyURL, fileManager: fileManager)
        }
        try removeIfPresent(markerURL, fileManager: fileManager)
        return .available(legacyRecord)
    }

    private func loadMarker(
        at url: URL,
        fileName: String,
        fileManager: FileManager
    ) throws -> ReconciliationMarker? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            try persistCorruptionBlock(
                at: url,
                legacyRecord: nil,
                durableRecord: nil,
                fileManager: fileManager
            )
            throw error
        }
        do {
            let marker = try JSONDecoder().decode(
                ReconciliationMarker.self,
                from: data
            )
            try validate(marker: marker, fileName: fileName)
            return marker
        } catch {
            _ = quarantineCopy(
                data,
                originalURL: url,
                rootDirectory: url.deletingLastPathComponent(),
                fileManager: fileManager
            )
            try persistCorruptionBlock(
                at: url,
                legacyRecord: nil,
                durableRecord: nil,
                fileManager: fileManager
            )
            throw error
        }
    }

    private func quarantineCopy(
        _ data: Data,
        originalURL: URL,
        rootDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        let quarantineDirectory = rootDirectory.appendingPathComponent(
            "quarantine",
            isDirectory: true
        )
        do {
            try prepare(quarantineDirectory, fileManager: fileManager)
            let destination = quarantineDirectory.appendingPathComponent(
                "\(originalURL.lastPathComponent).corrupt-\(UUID().uuidString)"
            )
            try data.write(to: destination, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            return true
        } catch {
            return false
        }
    }

    private func loadDurableRecord(
        at url: URL,
        fileName: String
    ) throws -> SimulatorCameraAuthorizationRecord {
        let record = try JSONDecoder().decode(
            SimulatorCameraAuthorizationRecord.self,
            from: Data(contentsOf: url)
        )
        try validate(record: record, fileName: fileName)
        let expectedURL = try durableURL(fileName: fileName)
        guard url.standardizedFileURL == expectedURL.standardizedFileURL else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }

    private func loadLegacyRecord(
        at url: URL,
        fileName: String
    ) throws -> SimulatorCameraAuthorizationRecord {
        let record = try JSONDecoder().decode(
            SimulatorCameraAuthorizationRecord.self,
            from: Data(contentsOf: url)
        )
        try validate(record: record, fileName: fileName)
        guard url.standardizedFileURL
            == legacyURL(fileName: fileName)?.standardizedFileURL else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }

    private func validate(
        record: SimulatorCameraAuthorizationRecord,
        fileName: String
    ) throws {
        guard journalFileName(
            deviceIdentifier: record.deviceIdentifier,
            bundleIdentifier: record.bundleIdentifier
        ) == fileName,
            [.notDetermined, .denied, .granted].contains(record.authorization),
            record.ownerProcessIdentity.map(processIdentityIsValid) != false
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func validate(
        marker: ReconciliationMarker,
        fileName: String
    ) throws {
        for record in [marker.legacyRecord, marker.durableRecord].compactMap({ $0 }) {
            try validate(record: record, fileName: fileName)
        }
        let isValid = switch marker.phase {
        case .suppressingLegacy:
            marker.legacyRecord != nil && marker.durableRecord != nil
        case .migratedLegacy:
            marker.legacyRecord != nil
        case .preservingDurable:
            marker.legacyRecord != nil && marker.durableRecord != nil
        case .corruptionBlocked:
            true
        }
        guard isValid else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func blockInconsistentReconciliation<Result>(
        markerURL: URL,
        legacyRecord: SimulatorCameraAuthorizationRecord?,
        durableRecord: SimulatorCameraAuthorizationRecord?,
        fileManager: FileManager
    ) throws -> Result {
        try persistCorruptionBlock(
            at: markerURL,
            legacyRecord: legacyRecord,
            durableRecord: durableRecord,
            fileManager: fileManager
        )
        throw CocoaError(.fileReadCorruptFile)
    }

    private func persistCorruptionBlock(
        at markerURL: URL,
        legacyRecord: SimulatorCameraAuthorizationRecord?,
        durableRecord: SimulatorCameraAuthorizationRecord?,
        fileManager: FileManager
    ) throws {
        try writeMarker(
            ReconciliationMarker(
                phase: .corruptionBlocked,
                legacyRecord: legacyRecord,
                durableRecord: durableRecord
            ),
            to: markerURL,
            fileManager: fileManager
        )
    }

    private func writeDurableRecord(
        _ record: SimulatorCameraAuthorizationRecord,
        fileName: String,
        fileManager: FileManager
    ) throws {
        let directory = try requiredDirectory()
        try prepare(directory, fileManager: fileManager)
        let url = try durableURL(fileName: fileName)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func writeMarker(
        _ marker: ReconciliationMarker,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let directory = url.deletingLastPathComponent()
        try prepare(directory, fileManager: fileManager)
        try JSONEncoder().encode(marker).write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func candidateFileNames(fileManager: FileManager) throws -> Set<String> {
        var fileNames: Set<String> = []
        var directories = [try requiredDirectory(), try markerDirectory()]
        if let legacyDirectory {
            directories.append(legacyDirectory)
        }
        for directory in directories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            fileNames.formUnion(
                urls.lazy
                    .filter { $0.pathExtension == "json" }
                    .map(\.lastPathComponent)
            )
        }
        return fileNames
    }

    private func durableURL(fileName: String) throws -> URL {
        try requiredDirectory().appendingPathComponent(fileName)
    }

    private func legacyURL(fileName: String) -> URL? {
        legacyDirectory?.appendingPathComponent(fileName)
    }

    private func markerDirectory() throws -> URL {
        try requiredDirectory()
            .appendingPathComponent("legacy-reconciliation", isDirectory: true)
    }

    private func markerURL(fileName: String) throws -> URL {
        try markerDirectory().appendingPathComponent(fileName)
    }

    private func requiredDirectory() throws -> URL {
        guard let directory else { throw CocoaError(.fileReadNoSuchFile) }
        return directory
    }

    private func journalFileName(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) -> String {
        hash([deviceIdentifier, bundleIdentifier]) + ".json"
    }

    private func prepare(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func removeIfPresent(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func quarantine(
        _ url: URL,
        rootDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        let quarantineDirectory = rootDirectory.appendingPathComponent(
            "quarantine",
            isDirectory: true
        )
        do {
            try prepare(quarantineDirectory, fileManager: fileManager)
            let destination = quarantineDirectory.appendingPathComponent(
                "\(url.lastPathComponent).corrupt-\(UUID().uuidString)"
            )
            try fileManager.moveItem(at: url, to: destination)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            return true
        } catch {
            return false
        }
    }

    private func processIdentityIsValid(_ identity: SimulatorProcessIdentity) -> Bool {
        identity.pid > 0
            && identity.startSeconds > 0
            && (0..<1_000_000).contains(identity.startMicroseconds)
    }

    private func hash(_ values: [String]) -> String {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b97f4a7c15
        for byte in values.joined(separator: "\0").utf8 {
            first ^= UInt64(byte)
            first &*= 0x100000001b3
            second ^= UInt64(byte) &+ 0x9d
            second = (second << 7) | (second >> 57)
            second &*= 0x9e3779b185ebca87
        }
        return String(format: "%016llx%016llx", first, second)
    }
}
