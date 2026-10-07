public import CmuxMobileConnect
public import CmuxMobileHost
public import CmuxPairing
import Foundation

/// B5's `MobileTrustStore` over the Mac's `trust:<user>` mirror (B6): the
/// account's own installs with their P-256 install key under
/// `MobileDeviceCredentials.installKeyID`. An install that leaves the
/// mirror (`install.revoke`) is gone from `device(install:)` before it is
/// yielded as revoked.
public actor TrustStoreMobileDevices: MobileTrustStore {
    private let mirror: TrustStoreMirror
    private let accountUserID: String
    private var known: Set<String> = []
    private var subscribers: [UUID: AsyncStream<String>.Continuation] = [:]
    private var follow: Task<Void, Never>?

    public init(mirror: TrustStoreMirror, accountUserID: String) {
        self.mirror = mirror
        self.accountUserID = accountUserID
    }

    public func device(install: String) async -> PairedDevice? {
        guard let device = await mirror.state?.devices[install], let key = device.publicKey.signingKey else { return nil }
        return PairedDevice(install: device.install, userID: accountUserID, keyID: MobileDeviceCredentials.installKeyID,
                            publicKey: key.x963Representation, displayName: device.name)
    }

    public func revocations() async -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        if follow == nil {
            known = Set(await mirror.state?.devices.keys.map { $0 } ?? [])
            let updates = await mirror.updates()
            follow = Task { [weak self] in
                for await state in updates {
                    guard let self else { return }
                    await self.apply(state)
                }
            }
        }
        return stream
    }

    /// Stops following the mirror (the host stopped).
    public func stop() {
        follow?.cancel()
        follow = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func apply(_ state: TrustStoreState) {
        let current = Set(state.devices.keys)
        let gone = known.subtracting(current)
        known = current
        for install in gone.sorted() {
            for continuation in subscribers.values { continuation.yield(install) }
        }
    }

    private func drop(_ id: UUID) {
        subscribers[id] = nil
    }
}
