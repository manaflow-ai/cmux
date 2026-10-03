internal import Dispatch

/// Coalesces browser discovery and isolates synchronous system and profile reads.
public actor BrowserInstalledBrowserDetectionService {
    private let scan: @Sendable () -> [InstalledBrowserCandidate]
    // Foundation/Launch Services discovery has no asynchronous API. This serial
    // I/O lane prevents a blocked scan from occupying the UI or cooperative pool.
    private let queue = DispatchQueue(label: "com.cmux.browser-discovery", qos: .utility)
    private var inFlight: Task<[InstalledBrowserCandidate], Never>?

    /// Creates a discovery owner.
    ///
    /// - Parameter scan: Synchronous discovery performed on the I/O lane. Tests
    ///   provide a fixture-backed scanner; the default scans the current Mac.
    public init(scan: @escaping @Sendable () -> [InstalledBrowserCandidate] = {
        BrowserInstalledBrowserDetector().detectInstalledBrowsers()
    }) {
        self.scan = scan
    }

    /// Returns a fresh discovery snapshot, sharing any scan already in progress.
    ///
    /// Cancellation does not interrupt an in-progress Foundation call. The one
    /// scan remains owned until it completes; callers discard canceled results.
    /// - Returns: Ranked installed browsers and their importable profiles.
    public func detectInstalledBrowsers() async -> [InstalledBrowserCandidate] {
        if let inFlight { return await inFlight.value }
        let scan = scan
        let queue = queue
        let task = Task {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: scan()) }
            }
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}
