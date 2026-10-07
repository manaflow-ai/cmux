import Foundation

/// Admits only paired, unrevoked devices of the account this Mac is signed
/// into, with a fresh proof bound to the link session (b5-mac-host.md 3).
public actor TrustStoreAuthorizer: MobileDeviceAuthorizer {
    public static let defaultProofWindow: TimeInterval = 120
    static let replayCapacity = 4096

    private let hostID: String
    private let accountUserID: String
    private let store: any MobileTrustStore
    private let proofWindow: TimeInterval
    private let now: @Sendable () -> Date
    private var seen: Set<String> = []
    private var seenOrder: [String] = []

    public init(hostID: String, accountUserID: String, store: any MobileTrustStore,
                proofWindow: TimeInterval = TrustStoreAuthorizer.defaultProofWindow,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.hostID = hostID
        self.accountUserID = accountUserID
        self.store = store
        self.proofWindow = proofWindow
        self.now = now
    }

    public func authorize(_ request: DeviceAuthRequest) async -> Result<MobileDevicePrincipal, MobileAuthFailure> {
        guard let proof = request.proof else { return .failure(.unauthenticated("hello has no device proof")) }
        guard proof.install == request.client.install else {
            return .failure(.unauthenticated("proof names another install"))
        }
        if let attestation = request.attestation, attestation.install != proof.install {
            return .failure(.unauthenticated("the carrier authenticated another device"))
        }
        let device: PairedDevice
        switch await pairedDevice(proof.install, userID: nil) {
        case .success(let found): device = found
        case .failure(let failure): return .failure(failure)
        }
        guard device.keyID == proof.keyID else { return .failure(.unauthenticated("unknown device key")) }
        let age = abs(now().timeIntervalSince1970 - Double(proof.issuedAt) / 1000)
        guard age <= proofWindow else { return .failure(.unauthenticated("device proof expired")) }
        guard proof.verifies(publicKey: device.publicKey, hostID: hostID, sessionID: request.sessionID) else {
            return .failure(.unauthenticated("device proof does not verify"))
        }
        let replayKey = "\(proof.install)|\(request.sessionID.uuidString)"
        guard !seen.contains(replayKey) else { return .failure(.unauthenticated("device proof replayed")) }
        remember(replayKey)
        return .success(MobileDevicePrincipal(install: device.install, userID: device.userID,
                                              platform: request.client.platform,
                                              appVersion: request.client.appVersion,
                                              displayName: device.displayName))
    }

    public func authorizeForwarded(install: String, userID: String?) async -> Result<MobileDevicePrincipal, MobileAuthFailure> {
        switch await pairedDevice(install, userID: userID) {
        case .success(let device):
            return .success(MobileDevicePrincipal(install: device.install, userID: device.userID, platform: "unknown",
                                                  appVersion: "unknown", displayName: device.displayName))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    public func revocations() async -> AsyncStream<String> {
        await store.revocations()
    }

    private func pairedDevice(_ install: String, userID: String?) async -> Result<PairedDevice, MobileAuthFailure> {
        guard let device = await store.device(install: install) else {
            return .failure(.forbidden("device is not paired with this Mac's account"))
        }
        guard !device.revoked else { return .failure(.forbidden("device was revoked")) }
        guard device.userID == accountUserID, userID == nil || userID == accountUserID else {
            return .failure(.forbidden("device belongs to another account"))
        }
        return .success(device)
    }

    private func remember(_ key: String) {
        seen.insert(key)
        seenOrder.append(key)
        if seenOrder.count > Self.replayCapacity {
            seen.remove(seenOrder.removeFirst())
        }
    }
}
