/// Stable identity for one interface-scoped Bonjour result.
public struct CmxIrohBonjourServiceID: Equatable, Hashable, Sendable {
    public let serviceName: String
    public let interfaceIndex: UInt32

    public init(serviceName: String, interfaceIndex: UInt32) {
        self.serviceName = serviceName
        self.interfaceIndex = interfaceIndex
    }
}

public enum CmxIrohBonjourPublisherEvent: Equatable, Sendable {
    case registered(CmxIrohBonjourServiceID)
    case policyDenied
    case failed(Int32)
}

public enum CmxIrohBonjourBrowserEvent: Equatable, Sendable {
    case resolved(CmxIrohBonjourServiceID, CmxIrohBonjourResolvedService)
    case removed(CmxIrohBonjourServiceID)
    case policyDenied
    case failed(Int32)
}

/// Replaces all interface-scoped registrations atomically from the caller's view.
public protocol CmxIrohBonjourPublishing: Sendable {
    func events() async -> AsyncStream<CmxIrohBonjourPublisherEvent>
    func replace(with advertisements: [CmxIrohLANAdvertisement]) async throws
    func stop() async
}

/// Browses only the declared cmux Iroh service and reports resolved TXT records.
public protocol CmxIrohBonjourBrowsing: Sendable {
    func events() async -> AsyncStream<CmxIrohBonjourBrowserEvent>
    func stop() async
}
