#if !canImport(dnssd)
/// dns_sd's `kDNSServiceErr_ServiceNotRunning`: no mDNS responder exists.
private let serviceNotRunning: Int32 = -65_742

/// Where dns_sd does not exist (Linux), nothing is published: `replace`
/// throws ``CmxIrohLANDiscoveryError/serviceFailure(_:)`` with dns_sd's
/// service-not-running code, the error a stopped mDNSResponder gives.
public actor CmxIrohSystemBonjourPublisher: CmxIrohBonjourPublishing {
    public init() {}

    public func events() -> AsyncStream<CmxIrohBonjourPublisherEvent> {
        AsyncStream { $0.finish() }
    }

    public func replace(with advertisements: [CmxIrohLANAdvertisement]) throws {
        guard advertisements.isEmpty else {
            throw CmxIrohLANDiscoveryError.serviceFailure(serviceNotRunning)
        }
    }

    public func stop() {}
}

/// Where dns_sd does not exist (Linux), browsing reports one
/// service-not-running failure and finds nothing.
public actor CmxIrohSystemBonjourBrowser: CmxIrohBonjourBrowsing {
    public init() {}

    public func replaceServiceNameAllowlist(_ serviceNames: Set<String>) {}

    public func events() -> AsyncStream<CmxIrohBonjourBrowserEvent> {
        AsyncStream { continuation in
            continuation.yield(.failed(serviceNotRunning))
            continuation.finish()
        }
    }

    public func stop() {}
}
#endif
