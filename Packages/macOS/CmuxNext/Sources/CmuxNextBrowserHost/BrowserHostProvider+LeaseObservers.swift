/// One registered lease consumer; `cancel()` (or dropping the provider)
/// stops it.
@MainActor
public final class ProviderLeaseObservation {
    private weak var provider: BrowserHostProvider?
    private let id: UInt64

    init(provider: BrowserHostProvider, id: UInt64) {
        self.provider = provider
        self.id = id
    }

    public func cancel() {
        provider?.leaseObservers.removeAll { $0.id == id }
    }
}

extension BrowserHostProvider {
    /// Registers a consumer of lease changes: `(targetId, lease)`, `nil` when
    /// a lease ends (release, session end, stop, tab gone, link drop). Every
    /// consumer hears every change, in registration order.
    public func observeLeases(_ consumer: @escaping (String, ProviderLease?) -> Void) -> ProviderLeaseObservation {
        nextLeaseObserverID += 1
        leaseObservers.append((id: nextLeaseObserverID, consumer: consumer))
        return ProviderLeaseObservation(provider: self, id: nextLeaseObserverID)
    }

    func notifyLease(_ targetID: String, _ lease: ProviderLease?) {
        // A consumer may cancel itself or another while being told.
        for observer in leaseObservers {
            observer.consumer(targetID, lease)
        }
    }
}
