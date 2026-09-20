import Foundation
import LocalAuthentication
import Security

/// Security.framework adapter for non-synchronizable device Keychain records.
struct MobileRemoteKeychainSecurity: MobileRemoteKeychainBackend, Sendable {
    private let namespace: MobileRemoteKeychainNamespace

    init(namespace: MobileRemoteKeychainNamespace) {
        self.namespace = namespace
    }

    func insert(
        value: Data,
        scope: MobileRemoteSecretScope,
        protection: MobileRemoteSecretProtection
    ) async throws {
        var query = identityQuery(for: scope)
        query[kSecValueData as String] = value
        switch protection {
        case .whenUnlockedThisDeviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .whenUnlockedThisDeviceOnlyUserPresence:
            query[kSecAttrAccessControl as String] = try accessControl(flags: [.userPresence])
        case .whenUnlockedThisDeviceOnlyBiometryCurrentSet:
            query[kSecAttrAccessControl as String] = try accessControl(flags: [.biometryCurrentSet])
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw map(status: status) }
    }

    func read(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws -> Data {
        var query = identityQuery(for: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        addAuthentication(to: &query, interaction: interaction)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw map(status: status) }
        guard let data = result as? Data else {
            throw MobileRemoteSecretStoreError.corruptedItem(Int32(errSecDecode))
        }
        return data
    }

    func updateValue(
        value: Data,
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws {
        var query = identityQuery(for: scope)
        addAuthentication(to: &query, interaction: interaction)
        // Only kSecValueData is supplied. Security.framework preserves the
        // existing SecAccessControl and accessibility policy atomically.
        let attributes: [String: Any] = [kSecValueData as String: value]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw map(status: status) }
    }

    func delete(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws {
        var query = identityQuery(for: scope)
        addAuthentication(to: &query, interaction: interaction)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess else { throw map(status: status) }
    }

    private func identityQuery(for scope: MobileRemoteSecretScope) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace.service,
            kSecAttrAccount as String: scope.keychainAccount,
            kSecAttrAccessGroup as String: namespace.accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func addAuthentication(
        to query: inout [String: Any],
        interaction: MobileRemoteSecretInteraction
    ) {
        switch interaction {
        case .nonInteractive:
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        case let .userInitiated(localizedReason):
            let context = LAContext()
            context.localizedReason = localizedReason
            context.interactionNotAllowed = false
            query[kSecUseAuthenticationContext as String] = context
        }
    }

    private func accessControl(flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &error
        ) else {
            _ = error?.takeRetainedValue()
            throw MobileRemoteSecretStoreError.invalidProtectionPolicy
        }
        return control
    }

    private func map(status: OSStatus) -> MobileRemoteSecretStoreError {
        switch status {
        case errSecItemNotFound:
            return .itemNotFound
        case errSecDuplicateItem:
            return .itemAlreadyExists
        case errSecMissingEntitlement:
            return .missingEntitlement(Int32(status))
        case errSecUserCanceled:
            return .userCancelled(Int32(status))
        case errSecAuthFailed:
            return .authenticationFailed(Int32(status))
        case errSecInteractionNotAllowed:
            return .interactionNotAllowed(Int32(status))
        case errSecDataNotAvailable:
            return .deviceLocked(Int32(status))
        case errSecDecode:
            return .corruptedItem(Int32(status))
        default:
            return .keychainFailure(Int32(status))
        }
    }
}
