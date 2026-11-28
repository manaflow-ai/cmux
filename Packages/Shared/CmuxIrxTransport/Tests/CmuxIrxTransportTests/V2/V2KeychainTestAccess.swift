import Foundation
@testable import CmuxIrxTransport

/// Each test owns one fake and accesses it only before or after awaiting its
/// serial store operation; no fake state is accessed concurrently across actors.
final class V2KeychainTestAccess: V2KeychainAccess, @unchecked Sendable {
    let supportsLegacyFileKeychain: Bool
    private(set) var values: [V2KeychainTestKey: Data] = [:]
    private(set) var reads: [V2KeychainTestKey] = []
    private(set) var adds: [V2KeychainTestKey] = []
    private(set) var deletes: [V2KeychainTestKey] = []
    private(set) var markerReads: [V2KeychainTestKey] = []
    private(set) var markerWrites: [V2KeychainTestKey] = []
    var readError: (any Error)?
    var legacyReadError: (any Error)?
    var addError: (any Error)?
    var duplicateWinner: Data?
    var deleteError: (any Error)?
    var markerReadError: (any Error)?
    var markerWriteError: (any Error)?
    private var migrationMarkers: Set<V2KeychainTestKey> = []

    init(supportsLegacyFileKeychain: Bool = false) {
        self.supportsLegacyFileKeychain = supportsLegacyFileKeychain
    }

    func seed(
        _ data: Data,
        service: String = "test.service",
        account: String = "test.account",
        accessGroup: String? = nil,
        dataProtection: Bool
    ) {
        values[V2KeychainTestKey(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )] = data
    }

    func value(
        service: String = "test.service",
        account: String = "test.account",
        accessGroup: String? = nil,
        dataProtection: Bool
    ) -> Data? {
        values[V2KeychainTestKey(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )]
    }

    func read(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Data? {
        if let readError { throw readError }
        if !dataProtection, let legacyReadError { throw legacyReadError }
        let key = V2KeychainTestKey(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )
        reads.append(key)
        return values[key]
    }

    func hasMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws -> Bool {
        if let markerReadError { throw markerReadError }
        let key = V2KeychainTestKey(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )
        markerReads.append(key)
        return migrationMarkers.contains(key)
    }

    func setMigrationMarker(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        if let markerWriteError { throw markerWriteError }
        let key = V2KeychainTestKey(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )
        markerWrites.append(key)
        migrationMarkers.insert(key)
    }

    func add(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        let key = V2KeychainTestKey(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )
        adds.append(key)
        if let addError {
            if let keychainError = addError as? V2KeychainAccessError,
               keychainError == .duplicate,
               let duplicateWinner {
                values[key] = duplicateWinner
            }
            throw addError
        }
        guard values[key] == nil else { throw V2KeychainAccessError.duplicate }
        values[key] = data
    }

    func delete(
        service: String,
        account: String,
        accessGroup: String?,
        dataProtection: Bool
    ) throws {
        if let deleteError { throw deleteError }
        let key = V2KeychainTestKey(
            service: service,
            account: account,
            accessGroup: accessGroup,
            dataProtection: dataProtection
        )
        deletes.append(key)
        values.removeValue(forKey: key)
    }
}
