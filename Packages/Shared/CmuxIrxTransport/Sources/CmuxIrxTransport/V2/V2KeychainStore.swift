public import Foundation

/// Persists one v2 value in the device-only Data Protection Keychain.
///
/// Reads first from the primary Data Protection Keychain. A value written by
/// an older macOS build is read only from the exact same service/account in
/// the legacy file keychain, then copied to the primary and verified before
/// the legacy item is removed. No legacy value is deleted when primary
/// persistence or verification fails. iOS callers leave file-keychain
/// migration disabled because the Security framework may treat both domains
/// as the same store there.
public struct V2KeychainStore: Sendable {
    private let service: String
    private let accessGroup: String?
    private let access: any V2KeychainAccess

    /// Creates a keychain store for one service namespace.
    /// - Parameters:
    ///   - service: The exact generic-password service.
    ///   - accessGroup: The optional signing-entitled keychain access group.
    ///   - access: The Security adapter; tests inject an in-memory adapter.
    public init(
        service: String,
        accessGroup: String? = nil,
        access: any V2KeychainAccess = V2SystemKeychainAccess()
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.access = access
    }

    /// Loads a validated value or persists the supplied candidate.
    /// - Parameters:
    ///   - account: The exact generic-password account.
    ///   - candidate: A fresh value used only when no value exists.
    ///   - validate: Validation performed before any value is persisted or migrated.
    /// - Returns: The committed value, including a concurrent writer's winner.
    /// - Throws: ``V2ControlFailure/persistenceFailed`` for keychain failures or invalid bytes.
    public func loadOrCreate(
        account: String,
        candidate: Data,
        validate: @Sendable (Data) throws -> Void
    ) throws -> Data {
        if let primary = try verifiedRead(dataProtection: true, account: account, validate: validate) {
            if try !hasMigrationMarker(account: account) {
                if access.supportsLegacyFileKeychain,
                   let legacy = try verifiedRead(dataProtection: false, account: account, validate: validate) {
                    // A previous migration may have committed the primary item
                    // and crashed before deleting the legacy copy. Reconcile only
                    // an exact byte-for-byte match; a mismatch is an unresolved
                    // identity conflict and must remain fail-closed across restarts.
                    guard legacy == primary else { throw V2ControlFailure.persistenceFailed }
                    try deleteLegacy(account: account)
                }
                // Once reconciliation succeeds, remember it on the primary item
                // so a locked or unavailable legacy domain cannot strand startup.
                try setMigrationMarker(account: account)
            }
            return primary
        }

        if access.supportsLegacyFileKeychain,
           let legacy = try verifiedRead(dataProtection: false, account: account, validate: validate) {
            let committed = try persist(
                legacy,
                account: account,
                validate: validate
            )
            // A duplicate during migration means another writer already
            // committed this exact scope. If its bytes differ, refuse to
            // choose a new identity or destroy the only legacy copy.
            guard committed == legacy else { throw V2ControlFailure.persistenceFailed }
            // The exact legacy item is retained unless the new copy was read
            // back and validated successfully above.
            try deleteLegacy(account: account)
            try setMigrationMarker(account: account)
            return committed
        }

        try validateOrFail(candidate, validate: validate)
        let committed = try persist(candidate, account: account, validate: validate)
        try setMigrationMarker(account: account)
        return committed
    }

    private func hasMigrationMarker(account: String) throws -> Bool {
        do {
            return try access.hasMigrationMarker(
                service: service,
                account: account,
                accessGroup: accessGroup,
                dataProtection: true
            )
        } catch {
            throw V2ControlFailure.persistenceFailed
        }
    }

    private func setMigrationMarker(account: String) throws {
        do {
            try access.setMigrationMarker(
                service: service,
                account: account,
                accessGroup: accessGroup,
                dataProtection: true
            )
        } catch {
            throw V2ControlFailure.persistenceFailed
        }
    }

    private func verifiedRead(
        dataProtection: Bool,
        account: String,
        validate: @Sendable (Data) throws -> Void
    ) throws -> Data? {
        do {
            guard let data = try access.read(
                service: service,
                account: account,
                accessGroup: accessGroup,
                dataProtection: dataProtection
            ) else { return nil }
            try validateOrFail(data, validate: validate)
            return data
        } catch let failure as V2ControlFailure {
            throw failure
        } catch {
            throw V2ControlFailure.persistenceFailed
        }
    }

    private func persist(
        _ data: Data,
        account: String,
        validate: @Sendable (Data) throws -> Void
    ) throws -> Data {
        do {
            try access.add(
                data,
                service: service,
                account: account,
                accessGroup: accessGroup,
                dataProtection: true
            )
        } catch let error as V2KeychainAccessError {
            guard error == .duplicate else { throw V2ControlFailure.persistenceFailed }
            // Another process won the race. Only return its value after an
            // exact primary read and validation.
            guard let winner = try verifiedRead(dataProtection: true, account: account, validate: validate) else {
                throw V2ControlFailure.persistenceFailed
            }
            return winner
        } catch {
            throw V2ControlFailure.persistenceFailed
        }
        guard let committed = try verifiedRead(dataProtection: true, account: account, validate: validate) else {
            throw V2ControlFailure.persistenceFailed
        }
        return committed
    }

    private func deleteLegacy(account: String) throws {
        do {
            try access.delete(
                service: service,
                account: account,
                accessGroup: accessGroup,
                dataProtection: false
            )
        } catch {
            throw V2ControlFailure.persistenceFailed
        }
    }

    private func validateOrFail(
        _ data: Data,
        validate: @Sendable (Data) throws -> Void
    ) throws {
        do {
            try validate(data)
        } catch let failure as V2ControlFailure {
            throw failure
        } catch {
            throw V2ControlFailure.persistenceFailed
        }
    }
}
