import Foundation

/// Persists the authorization that camera injection temporarily replaces.
///
/// Worker crashes cannot erase this record, so the host's durable Simulator
/// cleanup can restore the prior TCC state after relaunching the target app.
public struct SimulatorCameraAuthorizationStore: Sendable {
    private let directory: URL?
    private let legacyDirectory: URL?

    /// Creates a store in durable per-user Application Support by default.
    public init(
        directory: URL? = nil,
        legacyDirectory: URL? = nil,
        fileManager: FileManager = FileManager()
    ) {
        if let directory {
            self.directory = directory
            self.legacyDirectory = legacyDirectory
        } else {
            self.directory = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
                .appendingPathComponent("com.cmux.simulator-ownership", isDirectory: true)
                .appendingPathComponent("camera-authorizations", isDirectory: true)
            self.legacyDirectory = legacyDirectory ?? fileManager.temporaryDirectory
                .appendingPathComponent("com.cmux.simulator-ownership", isDirectory: true)
                .appendingPathComponent("camera-authorizations", isDirectory: true)
        }
    }

    package func save(
        _ authorization: SimulatorPrivacyAuthorization,
        deviceIdentifier: String,
        bundleIdentifier: String,
        ownerProcessIdentity: SimulatorProcessIdentity? = .parent
    ) throws {
        guard [.notDetermined, .denied, .granted].contains(authorization),
              let ownerProcessIdentity else {
            throw CocoaError(.fileWriteUnknown)
        }
        let hasLiveLegacyOwner = try migrateLegacyRecordIfPossible(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        guard !hasLiveLegacyOwner else {
            throw CocoaError(.fileWriteFileExists)
        }
        let existing = try record(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        let directory = try requiredDirectory()
        let fileManager = FileManager()
        try prepare(directory, fileManager: fileManager)
        let data = try JSONEncoder().encode(SimulatorCameraAuthorizationRecord(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier,
            authorization: existing?.authorization ?? authorization,
            ownerProcessIdentity: ownerProcessIdentity
        ))
        let url = try fileURL(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    package func authorization(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) throws -> SimulatorPrivacyAuthorization? {
        try record(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )?.authorization
    }

    package func record(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) throws -> SimulatorCameraAuthorizationRecord? {
        let hasLiveLegacyOwner = try migrateLegacyRecordIfPossible(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        guard !hasLiveLegacyOwner else { return nil }
        let url = try fileURL(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        guard FileManager().fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(
            SimulatorCameraAuthorizationRecord.self,
            from: Data(contentsOf: url)
        )
        try validate(
            record,
            expectedDeviceIdentifier: deviceIdentifier,
            expectedBundleIdentifier: bundleIdentifier,
            sourceURL: url
        )
        return record
    }

    package func records() throws -> (
        records: [SimulatorCameraAuthorizationRecord],
        hadFailures: Bool
    ) {
        let directory = try requiredDirectory()
        let fileManager = FileManager()
        let migration = try migrateLegacyRecords(fileManager: fileManager)
        var hadFailures = migration.hadFailures
        guard fileManager.fileExists(atPath: directory.path) else {
            return ([], hadFailures)
        }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var records: [SimulatorCameraAuthorizationRecord] = []
        for url in urls where url.pathExtension == "json" {
            guard !migration.liveLegacyFileNames.contains(url.lastPathComponent) else {
                continue
            }
            do {
                let record = try JSONDecoder().decode(
                    SimulatorCameraAuthorizationRecord.self,
                    from: Data(contentsOf: url)
                )
                try validate(
                    record,
                    expectedDeviceIdentifier: record.deviceIdentifier,
                    expectedBundleIdentifier: record.bundleIdentifier,
                    sourceURL: url
                )
                records.append(record)
            } catch {
                hadFailures = true
                _ = quarantine(
                    url,
                    rootDirectory: directory,
                    fileManager: fileManager
                )
            }
        }
        return (records, hadFailures)
    }

    package func remove(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) throws {
        guard try record(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        ) != nil else { return }
        let url = try fileURL(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        try FileManager().removeItem(at: url)
    }

    private func fileURL(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) throws -> URL {
        try requiredDirectory().appendingPathComponent(
            hash([deviceIdentifier, bundleIdentifier]) + ".json"
        )
    }

    private func requiredDirectory() throws -> URL {
        guard let directory else { throw CocoaError(.fileReadNoSuchFile) }
        return directory
    }

    private func validate(
        _ record: SimulatorCameraAuthorizationRecord,
        expectedDeviceIdentifier: String,
        expectedBundleIdentifier: String,
        sourceURL: URL
    ) throws {
        let expectedURL = try fileURL(
            deviceIdentifier: record.deviceIdentifier,
            bundleIdentifier: record.bundleIdentifier
        )
        guard record.deviceIdentifier == expectedDeviceIdentifier,
              record.bundleIdentifier == expectedBundleIdentifier,
              [.notDetermined, .denied, .granted].contains(record.authorization),
              record.ownerProcessIdentity.map(processIdentityIsValid) != false,
              sourceURL.standardizedFileURL == expectedURL.standardizedFileURL
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// Returns true when a live legacy owner must keep the only journal.
    private func migrateLegacyRecordIfPossible(
        deviceIdentifier: String,
        bundleIdentifier: String
    ) throws -> Bool {
        let durableDirectory = try requiredDirectory()
        guard let legacyDirectory,
              legacyDirectory.standardizedFileURL
                != durableDirectory.standardizedFileURL else { return false }
        let legacyURL = legacyDirectory.appendingPathComponent(
            hash([deviceIdentifier, bundleIdentifier]) + ".json"
        )
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: legacyURL.path) else { return false }
        let record = try JSONDecoder().decode(
            SimulatorCameraAuthorizationRecord.self,
            from: Data(contentsOf: legacyURL)
        )
        try validateLegacy(
            record,
            expectedDeviceIdentifier: deviceIdentifier,
            expectedBundleIdentifier: bundleIdentifier,
            sourceURL: legacyURL
        )
        guard !record.isOwnedByRunningProcess else { return true }
        let destination = try fileURL(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        var shouldWriteLegacyRecord = true
        if fileManager.fileExists(atPath: destination.path) {
            do {
                let durableRecord = try JSONDecoder().decode(
                    SimulatorCameraAuthorizationRecord.self,
                    from: Data(contentsOf: destination)
                )
                try validate(
                    durableRecord,
                    expectedDeviceIdentifier: deviceIdentifier,
                    expectedBundleIdentifier: bundleIdentifier,
                    sourceURL: destination
                )
                shouldWriteLegacyRecord = !durableRecord.isOwnedByRunningProcess
            } catch {
                guard quarantine(
                    destination,
                    rootDirectory: durableDirectory,
                    fileManager: fileManager
                ) else { throw error }
            }
        }
        if shouldWriteLegacyRecord {
            let directory = try requiredDirectory()
            try prepare(directory, fileManager: fileManager)
            try JSONEncoder().encode(record).write(to: destination, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        }
        try fileManager.removeItem(at: legacyURL)
        return false
    }

    private func migrateLegacyRecords(
        fileManager: FileManager
    ) throws -> (
        hadFailures: Bool,
        liveLegacyFileNames: Set<String>
    ) {
        let durableDirectory = try requiredDirectory()
        guard let legacyDirectory,
              legacyDirectory.standardizedFileURL
                != durableDirectory.standardizedFileURL,
              fileManager.fileExists(atPath: legacyDirectory.path) else {
            return (false, [])
        }
        let urls = try fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var hadFailures = false
        var liveLegacyFileNames: Set<String> = []
        for url in urls where url.pathExtension == "json" {
            do {
                let record = try JSONDecoder().decode(
                    SimulatorCameraAuthorizationRecord.self,
                    from: Data(contentsOf: url)
                )
                try validateLegacy(
                    record,
                    expectedDeviceIdentifier: record.deviceIdentifier,
                    expectedBundleIdentifier: record.bundleIdentifier,
                    sourceURL: url
                )
                if try migrateLegacyRecordIfPossible(
                    deviceIdentifier: record.deviceIdentifier,
                    bundleIdentifier: record.bundleIdentifier
                ) {
                    liveLegacyFileNames.insert(url.lastPathComponent)
                }
            } catch {
                hadFailures = true
                _ = quarantine(
                    url,
                    rootDirectory: legacyDirectory,
                    fileManager: fileManager
                )
            }
        }
        return (hadFailures, liveLegacyFileNames)
    }

    private func validateLegacy(
        _ record: SimulatorCameraAuthorizationRecord,
        expectedDeviceIdentifier: String,
        expectedBundleIdentifier: String,
        sourceURL: URL
    ) throws {
        guard let legacyDirectory else { throw CocoaError(.fileReadNoSuchFile) }
        let expectedURL = legacyDirectory.appendingPathComponent(
            hash([record.deviceIdentifier, record.bundleIdentifier]) + ".json"
        )
        guard record.deviceIdentifier == expectedDeviceIdentifier,
              record.bundleIdentifier == expectedBundleIdentifier,
              [.notDetermined, .denied, .granted].contains(record.authorization),
              record.ownerProcessIdentity.map(processIdentityIsValid) != false,
              sourceURL.standardizedFileURL == expectedURL.standardizedFileURL
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
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
