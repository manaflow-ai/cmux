public import CmuxNextBrowserAutomation

/// One registered input consumer; `cancel()` (or dropping the provider)
/// stops it.
@MainActor
public final class ProviderInputObservation {
    private weak var provider: BrowserHostProvider?
    private let id: UInt64

    init(provider: BrowserHostProvider, id: UInt64) {
        self.provider = provider
        self.id = id
    }

    public func cancel() {
        provider?.inputObservers.removeAll { $0.id == id }
    }
}

extension BrowserHostProvider {
    /// Registers a consumer of agent inputs: the `event` of every `input`
    /// frame (automation.input v1, unvalidated here), in arrival order. Every
    /// consumer hears every input, in registration order.
    public func observeInputs(_ consumer: @escaping (DriverJSON) -> Void) -> ProviderInputObservation {
        nextInputObserverID += 1
        inputObservers.append((id: nextInputObserverID, consumer: consumer))
        return ProviderInputObservation(provider: self, id: nextInputObserverID)
    }

    func notifyInput(_ event: DriverJSON) {
        // A consumer may cancel itself or another while being told.
        for observer in inputObservers {
            observer.consumer(event)
        }
    }
}
