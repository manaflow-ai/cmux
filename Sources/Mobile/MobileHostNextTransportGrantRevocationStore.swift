#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

/// Device-only durable denylist for DEBUG next-transport grants. The actor
/// serializes complete read/modify/write transactions, including suspension,
/// and fails closed rather than evicting still-authoritative revocations.
actor MobileHostNextTransportGrantRevocationStore {
    private let keychain: any CmxIrohSecureCredentialStoring
    let account = "all"
    private let maximumGrantIDs = 1_024
    private var pendingUpdate: Task<Void, Error>?
    enum Failure: Error { case capacityExceeded }

    init(keychain: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(
        service: "dev.cmux.nextTransport.revokedGrants")) {
        self.keychain = keychain
    }

    func load() async throws -> Set<String> {
        try await pendingUpdate?.value
        return try await readPersisted()
    }

    private func readPersisted() async throws -> Set<String> {
        guard let data = try await keychain.read(account: account) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: data))
    }

    func revoke(_ grantIDs: Set<String>) async throws {
        guard !grantIDs.isEmpty else { return }
        let previous = pendingUpdate
        let update = Task {
            try await previous?.value
            var all = try await readPersisted()
            all.formUnion(grantIDs)
            guard all.count <= maximumGrantIDs else { throw Failure.capacityExceeded }
            let data = try JSONEncoder().encode(all.sorted())
            try await keychain.write(
                data,
                account: account,
                accessibility: .afterFirstUnlockThisDeviceOnly)
        }
        pendingUpdate = update
        try await update.value
    }
}
#endif
