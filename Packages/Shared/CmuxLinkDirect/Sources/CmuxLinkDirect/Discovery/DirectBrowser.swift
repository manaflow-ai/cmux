import Foundation
import Network
import os

/// Browses `_cmux._tcp` on the local link and streams the current set of
/// hosts on every change (NWBrowser events; no polling). Needs the Local
/// Network permission and `NSBonjourServices` on iOS.
public final class DirectBrowser: Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "cmux.direct.browser")
    private let started = OSAllocatedUnfairLock(initialState: false)

    public init() {
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: DirectEndpoint.serviceType, domain: nil), using: NWParameters())
    }

    /// Starts browsing on the first call. The stream ends on `stop()`.
    public func results() -> AsyncStream<[DirectDiscoveredHost]> {
        let (stream, continuation) = AsyncStream<[DirectDiscoveredHost]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        browser.browseResultsChangedHandler = { results, _ in
            continuation.yield(results.compactMap(Self.host(from:)).sorted { $0.serviceName < $1.serviceName })
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: continuation.finish()
            default: break
            }
        }
        let first = started.withLock { started -> Bool in
            defer { started = true }
            return !started
        }
        if first { browser.start(queue: queue) }
        return stream
    }

    public func stop() {
        browser.cancel()
    }

    static func host(from result: NWBrowser.Result) -> DirectDiscoveredHost? {
        guard case let .service(name, _, domain, _) = result.endpoint else { return nil }
        var hostID: String?
        if case let .bonjour(txt) = result.metadata { hostID = txt["host"] }
        return DirectDiscoveredHost(serviceName: name, domain: domain, hostID: hostID)
    }
}
