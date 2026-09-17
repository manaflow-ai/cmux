public import Foundation

/// Loads this device's identity or mints and persists one.
public struct CloudDeviceIdentityResolver: Sendable {
    /// Why no identity could be resolved.
    public enum Failure: Error, Equatable, Sendable {
        /// The store is locked or unreadable; retry later instead of re-minting.
        case storeUnavailable
        /// A fresh identity could not be persisted.
        case persistFailed(String)
    }

    private let store: any CloudDeviceIdentityStoring

    /// Creates a resolver over `store`.
    public init(store: any CloudDeviceIdentityStoring) {
        self.store = store
    }

    /// The stored identity, or a newly minted one that is now stored.
    public func resolve() throws -> CloudDeviceIdentity {
        switch store.read() {
        case .found(let identity):
            return identity
        case .unavailable:
            throw Failure.storeUnavailable
        case .absent:
            let minted = CloudDeviceIdentity.mint()
            do {
                try store.write(minted)
            } catch {
                throw Failure.persistFailed(String(describing: error))
            }
            return minted
        }
    }
}
