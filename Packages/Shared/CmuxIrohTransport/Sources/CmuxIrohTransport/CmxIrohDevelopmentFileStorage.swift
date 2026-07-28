public import Foundation

/// DEBUG-only endpoint-identity persistence for ad-hoc app builds.
///
/// Ad-hoc macOS and Simulator builds have no provisioning-profile Keychain
/// access group, so the data-protection Keychain returns
/// `errSecMissingEntitlement`. Production compositions must keep using
/// ``CmxIrohKeychainIdentityStore``.
public final class CmxIrohDevelopmentFileIdentityStore:
    CmxIrohSecureIdentityStoring,
    @unchecked Sendable
{
    private let directory: URL

    /// Creates a store inside a tag-specific application-support directory.
    public init(directory: URL) {
        self.directory = directory
    }

    public func read(account: String) throws -> Data? {
        try CmxIrohDevelopmentFileStorage.read(
            account: account,
            directory: directory
        )
    }

    public func write(_ data: Data, account: String) throws {
        try CmxIrohDevelopmentFileStorage.write(
            data,
            account: account,
            directory: directory
        )
    }

    public func delete(account: String) throws {
        try CmxIrohDevelopmentFileStorage.delete(
            account: account,
            directory: directory
        )
    }

    public func deleteAll() throws {
        try CmxIrohDevelopmentFileStorage.deleteAll(in: directory)
    }
}

/// DEBUG-only capability persistence for ad-hoc app builds.
///
/// Records remain scoped to the app sandbox and are written with 0600 mode.
/// Production compositions must keep using
/// ``CmxIrohKeychainCredentialStore`` so capabilities receive hardware-backed
/// data protection where the platform provides it.
public actor CmxIrohDevelopmentFileCredentialStore:
    CmxIrohSecureCredentialStoring
{
    private let directory: URL

    /// Creates a store inside a tag-specific application-support directory.
    public init(directory: URL) {
        self.directory = directory
    }

    public func read(account: String) throws -> Data? {
        try CmxIrohDevelopmentFileStorage.read(
            account: account,
            directory: directory
        )
    }

    public func write(
        _ data: Data,
        account: String,
        accessibility _: CmxIrohSecureCredentialAccessibility
    ) throws {
        try CmxIrohDevelopmentFileStorage.write(
            data,
            account: account,
            directory: directory
        )
    }

    public func delete(account: String) throws {
        try CmxIrohDevelopmentFileStorage.delete(
            account: account,
            directory: directory
        )
    }

    public func deleteAll() throws {
        try CmxIrohDevelopmentFileStorage.deleteAll(in: directory)
    }
}

private enum CmxIrohDevelopmentFileStorage {
    private static let maximumRecordByteCount = 8 * 1_024 * 1_024
    private static let recordExtension = "cmux-iroh"

    static func read(account: String, directory: URL) throws -> Data? {
        let file = try recordURL(account: account, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            guard data.count <= maximumRecordByteCount else {
                throw CmxIrohDevelopmentFileStoreError.recordTooLarge
            }
            return data
        } catch let error as CmxIrohDevelopmentFileStoreError {
            throw error
        } catch {
            throw CmxIrohDevelopmentFileStoreError.storageFailure
        }
    }

    static func write(_ data: Data, account: String, directory: URL) throws {
        guard data.count <= maximumRecordByteCount else {
            throw CmxIrohDevelopmentFileStoreError.recordTooLarge
        }
        let file = try recordURL(account: account, directory: directory)
        do {
            try prepare(directory: directory)
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path
            )
        } catch {
            throw CmxIrohDevelopmentFileStoreError.storageFailure
        }
    }

    static func delete(account: String, directory: URL) throws {
        let file = try recordURL(account: account, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw CmxIrohDevelopmentFileStoreError.storageFailure
        }
    }

    static func deleteAll(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        do {
            let records = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            for record in records where record.pathExtension == recordExtension {
                let values = try record.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                try FileManager.default.removeItem(at: record)
            }
        } catch {
            throw CmxIrohDevelopmentFileStoreError.storageFailure
        }
    }

    private static func prepare(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    private static func recordURL(account: String, directory: URL) throws -> URL {
        guard !account.isEmpty,
              account.utf8.count <= 1_024,
              account.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 48...57, 65...90, 95, 97...122:
                      true
                  default:
                      false
                  }
              }) else {
            throw CmxIrohDevelopmentFileStoreError.invalidAccount
        }
        return directory.appendingPathComponent(account)
            .appendingPathExtension(recordExtension)
    }
}
