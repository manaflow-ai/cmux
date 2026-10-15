import Foundation

/// The first answer to a ``BrowserPageBusyProbe`` run: the page's, or the
/// deadline's. Later deliveries are ignored.
@MainActor
final class BrowserPageBusyProbeAnswer {
    private var result: BrowserPageBusyProbe?
    private var waiter: CheckedContinuation<BrowserPageBusyProbe, Never>?

    func deliver(_ value: BrowserPageBusyProbe) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func value() async -> BrowserPageBusyProbe {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}
