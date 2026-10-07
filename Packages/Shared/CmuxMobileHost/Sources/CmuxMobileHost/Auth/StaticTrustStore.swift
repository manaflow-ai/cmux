import Foundation

/// An in-memory trust store for tests and DEV builds until B6's mirror lands.
public actor StaticTrustStore: MobileTrustStore {
    private var devices: [String: PairedDevice]
    private var subscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    public init(devices: [PairedDevice] = []) {
        self.devices = Dictionary(devices.map { ($0.install, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func device(install: String) -> PairedDevice? { devices[install] }

    public func upsert(_ device: PairedDevice) {
        devices[device.install] = device
    }

    /// Marks the device revoked and tells every subscriber.
    public func revoke(_ install: String) {
        devices[install]?.revoked = true
        for continuation in subscribers.values { continuation.yield(install) }
    }

    public func revocations() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
