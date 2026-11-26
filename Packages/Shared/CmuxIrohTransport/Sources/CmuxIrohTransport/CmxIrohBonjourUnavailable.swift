#if !canImport(dnssd)
// Platforms without DNS-SD (the Linux package lane) have no system Bonjour.
// These stand-ins keep the system publisher's and browser's names, so the
// defaults that name them still compile: the publisher refuses with
// kDNSServiceErr_Unsupported and the browser reports nothing. Callers there
// inject their own.
private let dnsServiceUnsupported: Int32 = -65544

/// Bonjour publishing where no DNS-SD exists: every advertisement is refused.
public actor CmxIrohSystemBonjourPublisher: CmxIrohBonjourPublishing {
    public init() {}

    public func events() -> AsyncStream<CmxIrohBonjourPublisherEvent> {
        AsyncStream { $0.finish() }
    }

    public func replace(with advertisements: [CmxIrohLANAdvertisement]) throws {
        guard advertisements.isEmpty else {
            throw CmxIrohLANDiscoveryError.serviceFailure(dnsServiceUnsupported)
        }
    }

    public func stop() {}
}

/// Bonjour browsing where no DNS-SD exists: it never finds a service.
public actor CmxIrohSystemBonjourBrowser: CmxIrohBonjourBrowsing {
    public init() {}

    public func replaceServiceNameAllowlist(_ serviceNames: Set<String>) {}

    public func events() -> AsyncStream<CmxIrohBonjourBrowserEvent> {
        AsyncStream { $0.finish() }
    }

    public func stop() {}
}
#endif
