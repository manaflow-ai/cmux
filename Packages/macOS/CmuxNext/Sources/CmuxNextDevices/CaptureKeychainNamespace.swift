public import CmuxNextCompat
public import Foundation

/// The result returned by the protected screen-capture keychain actions.
/// It intentionally contains no service, account, identity or secret values.
public struct DeviceHubCaptureCleanupResult: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case ok
        case invalidLease = "invalid_lease"
        case bundleMismatch = "bundle_mismatch"
        case hubNotQuiescent = "hub_not_quiescent"
        case namespaceNotEmpty = "namespace_not_empty"
        case ownershipMissing = "ownership_missing"
        case ownershipMismatch = "ownership_mismatch"
        case markerVerificationFailed = "marker_verification_failed"
        case keychainReadFailed = "keychain_read_failed"
        case verificationFailed = "verification_failed"
        case unavailable
    }

    public let ok: Bool
    public let code: Code
    public let identityRemoved: Int
    public let relaysRemoved: Int
    public let verifiedAbsent: Bool
    /// Only the app's DeviceHub writer, never the whole capture host.
    public let hubQuiescent: Bool

    public init(ok: Bool, code: Code, identityRemoved: Int = 0, relaysRemoved: Int = 0,
                verifiedAbsent: Bool = false, hubQuiescent: Bool = false) {
        self.ok = ok
        self.code = code
        self.identityRemoved = identityRemoved
        self.relaysRemoved = relaysRemoved
        self.verifiedAbsent = verifiedAbsent
        self.hubQuiescent = hubQuiescent
    }

    public static func success(identityRemoved: Int, relaysRemoved: Int) -> Self {
        Self(ok: true, code: .ok, identityRemoved: identityRemoved, relaysRemoved: relaysRemoved,
             verifiedAbsent: true, hubQuiescent: true)
    }

    public static func failure(_ code: Code) -> Self { Self(ok: false, code: code) }
}

/// The exact, lease-bound keychain namespace used by protected screen captures.
/// A marker is written only after both keychain stores are proven empty, so a
/// later cleanup can prove that the namespace belongs to this run.
public struct CaptureKeychainNamespace: Sendable {
    public static let markerAccount = "capture-lease"

    public init() {}

    public func prepare(bundleIdentifier: String, leaseID: String, loginKeychain: LoginKeychain) -> DeviceHubCaptureCleanupResult {
        do {
            try validate(bundleIdentifier: bundleIdentifier, leaseID: leaseID)
            let stores = stores(bundleIdentifier: bundleIdentifier, loginKeychain: loginKeychain)
            guard try allAccounts(in: stores).isEmpty else { return .failure(.namespaceNotEmpty) }
            let marker = Data(leaseID.utf8)
            try stores[0].write(marker, account: Self.markerAccount)
            guard try stores[0].read(Self.markerAccount) == marker else {
                return .failure(.markerVerificationFailed)
            }
            return .success(identityRemoved: 0, relaysRemoved: 0)
        } catch let failure as CaptureKeychainFailure {
            return .failure(failure.code)
        } catch {
            return .failure(.keychainReadFailed)
        }
    }

    public func cleanup(bundleIdentifier: String, leaseID: String, loginKeychain: LoginKeychain) -> DeviceHubCaptureCleanupResult {
        do {
            try validate(bundleIdentifier: bundleIdentifier, leaseID: leaseID)
            let stores = stores(bundleIdentifier: bundleIdentifier, loginKeychain: loginKeychain)
            guard let marker = try stores[0].read(Self.markerAccount) else {
                return .failure(.ownershipMissing)
            }
            guard marker == Data(leaseID.utf8) else { return .failure(.ownershipMismatch) }

            let accountSets = try stores.map { try Set($0.accountsThrowing()) }
            let all = accountSets.reduce(into: Set<String>()) { $0.formUnion($1) }
            let identity = Set(DeviceIdentity.captureIdentityAccounts)
            let relayIDs = Set(all.compactMap { account -> String? in
                guard account.hasPrefix("relay-"), account.count > 6 else { return nil }
                return String(account.dropFirst(6))
            })
            let relayAccounts = Set(relayIDs.map { "relay-\($0)" })
            let expected = identity.union(relayAccounts).union([Self.markerAccount])
            guard all.isSubset(of: expected) else { return .failure(.namespaceNotEmpty) }

            let removable = identity.union(relayAccounts)
            for account in removable {
                for store in stores { try store.delete(account) }
            }
            for store in stores {
                for account in removable where try store.read(account) != nil {
                    return .failure(.verificationFailed)
                }
            }
            // Re-enumerate before deleting the ownership marker. This catches
            // a late relay/identity writer and keeps the marker retryable.
            for store in stores {
                let remaining = Set(try store.accountsThrowing())
                guard remaining.isEmpty || remaining == [Self.markerAccount] else {
                    return .failure(.namespaceNotEmpty)
                }
            }
            // Keep the ownership marker until every other account is verified;
            // a failed read/delete must leave cleanup retryable.
            for store in stores { try store.delete(Self.markerAccount) }
            for store in stores where try store.read(Self.markerAccount) != nil {
                return .failure(.verificationFailed)
            }
            for store in stores where try !store.accountsThrowing().isEmpty {
                return .failure(.verificationFailed)
            }
            return .success(identityRemoved: all.intersection(identity).count,
                            relaysRemoved: relayIDs.count)
        } catch let failure as CaptureKeychainFailure {
            return .failure(failure.code)
        } catch {
            return .failure(.keychainReadFailed)
        }
    }

    private func stores(bundleIdentifier: String, loginKeychain: LoginKeychain) -> [DeviceKeychain] {
        let service = bundleIdentifier + ".device-hub"
        return [DeviceKeychain(service: service, loginKeychain: loginKeychain),
                DeviceKeychain(service: service, dataProtection: true, loginKeychain: loginKeychain)]
    }

    private func allAccounts(in stores: [DeviceKeychain]) throws -> Set<String> {
        try stores.reduce(into: Set<String>()) { result, store in
            result.formUnion(try store.accountsThrowing())
        }
    }

    private func validate(bundleIdentifier: String, leaseID: String) throws {
        guard !bundleIdentifier.isEmpty, !bundleIdentifier.contains("/") else {
            throw CaptureKeychainFailure(.bundleMismatch)
        }
        guard leaseID.count == 24, leaseID.unicodeScalars.allSatisfy({ scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }) else {
            throw CaptureKeychainFailure(.invalidLease)
        }
    }

    private struct CaptureKeychainFailure: Error {
        let code: DeviceHubCaptureCleanupResult.Code
        init(_ code: DeviceHubCaptureCleanupResult.Code) { self.code = code }
    }
}
