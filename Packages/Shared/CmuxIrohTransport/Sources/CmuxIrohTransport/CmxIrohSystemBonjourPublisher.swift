import Darwin
@preconcurrency import Dispatch
import dnssd
import Foundation

private final class CmxIrohBonjourRegisterCallbackBox: @unchecked Sendable {
    let handler: @Sendable (Int32) -> Void

    init(handler: @escaping @Sendable (Int32) -> Void) {
        self.handler = handler
    }
}

private let cmxIrohBonjourServiceRegisterCallback: DNSServiceRegisterReply = {
    _, _, errorCode, _, _, _, context in
    guard let context else { return }
    Unmanaged<CmxIrohBonjourRegisterCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handler(errorCode)
}

private let cmxIrohBonjourRecordRegisterCallback: DNSServiceRegisterRecordReply = {
    _, _, _, errorCode, context in
    guard let context else { return }
    Unmanaged<CmxIrohBonjourRegisterCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handler(errorCode)
}

/// Low-level DNS-SD publisher with an explicit opaque SRV target.
///
/// It does not open a UDP listener and never asks Bonjour to substitute the
/// computer name. Each service is interface-scoped and has matching A/AAAA
/// records registered for its rotating opaque host target.
public actor CmxIrohSystemBonjourPublisher: CmxIrohBonjourPublishing {
    private struct Registration {
        let serviceRef: DNSServiceRef
        let addressRef: DNSServiceRef
        let callbackContexts: [UnsafeMutableRawPointer]
    }

    private let queue = DispatchQueue(label: "dev.cmux.iroh.bonjour.publisher")
    private var registrations: [Registration] = []
    private var observers: [
        UUID: AsyncStream<CmxIrohBonjourPublisherEvent>.Continuation
    ] = [:]

    public init() {}

    public func events() -> AsyncStream<CmxIrohBonjourPublisherEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    public func replace(with advertisements: [CmxIrohLANAdvertisement]) async throws {
        guard advertisements.count <= CmxIrohLANAdvertisementBuilder.maximumInterfaceCount,
              Set(advertisements.map(\.interfaceIndex)).count == advertisements.count else {
            throw CmxIrohLANDiscoveryError.invalidAdvertisement
        }
        stopRegistrations()
        do {
            for advertisement in advertisements {
                registrations.append(try register(advertisement))
            }
        } catch {
            stopRegistrations()
            throw error
        }
    }

    public func stop() {
        stopRegistrations()
        for observer in observers.values { observer.finish() }
        observers.removeAll(keepingCapacity: false)
    }

    private func register(_ advertisement: CmxIrohLANAdvertisement) throws -> Registration {
        guard advertisement.hostTarget == "h-\(advertisement.alias).local.",
              advertisement.addresses.count <= CmxIrohLANTXTRecord.maximumAddressCount else {
            throw CmxIrohLANDiscoveryError.invalidAdvertisement
        }
        var callbackContexts: [UnsafeMutableRawPointer] = []
        var addressRef: DNSServiceRef?
        var serviceRef: DNSServiceRef?

        let addressCreateError = DNSServiceCreateConnection(&addressRef)
        guard addressCreateError == kDNSServiceErr_NoError,
              let addressRef else {
            throw Self.error(addressCreateError)
        }
        let addressQueueError = DNSServiceSetDispatchQueue(addressRef, queue)
        guard addressQueueError == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(addressRef)
            throw Self.error(addressQueueError)
        }

        do {
            var registeredIPAddresses: Set<String> = []
            for address in advertisement.addresses {
                // Multiple Iroh sockets may share one IP with different ports.
                // DNS A/AAAA records describe only the host, so register each
                // canonical IP once while retaining every socket in TXT.
                guard registeredIPAddresses.insert(address.ipAddress).inserted else {
                    continue
                }
                let callback = CmxIrohBonjourRegisterCallbackBox { [weak self] errorCode in
                    guard errorCode != kDNSServiceErr_NoError else { return }
                    Task { await self?.handle(errorCode) }
                }
                let context = Unmanaged.passRetained(callback).toOpaque()
                callbackContexts.append(context)
                let record = try Self.addressRecord(address)
                var recordRef: DNSRecordRef?
                let registerError = record.data.withUnsafeBytes { bytes in
                    DNSServiceRegisterRecord(
                        addressRef,
                        &recordRef,
                        DNSServiceFlags(kDNSServiceFlagsUnique),
                        advertisement.interfaceIndex,
                        advertisement.hostTarget,
                        record.type,
                        UInt16(kDNSServiceClass_IN),
                        UInt16(bytes.count),
                        bytes.baseAddress,
                        60,
                        cmxIrohBonjourRecordRegisterCallback,
                        context
                    )
                }
                guard registerError == kDNSServiceErr_NoError else {
                    throw Self.error(registerError)
                }
            }

            let serviceID = CmxIrohBonjourServiceID(
                serviceName: advertisement.alias,
                interfaceIndex: advertisement.interfaceIndex
            )
            let callback = CmxIrohBonjourRegisterCallbackBox { [weak self] errorCode in
                Task { await self?.handle(errorCode, serviceID: serviceID) }
            }
            let context = Unmanaged.passRetained(callback).toOpaque()
            callbackContexts.append(context)
            let registerError = advertisement.txtRecord.withUnsafeBytes { bytes in
                DNSServiceRegister(
                    &serviceRef,
                    DNSServiceFlags(kDNSServiceFlagsNoAutoRename),
                    advertisement.interfaceIndex,
                    advertisement.alias,
                    CmxIrohLANAdvertisement.serviceType,
                    CmxIrohLANAdvertisement.domain,
                    advertisement.hostTarget,
                    advertisement.port.bigEndian,
                    UInt16(bytes.count),
                    bytes.baseAddress,
                    cmxIrohBonjourServiceRegisterCallback,
                    context
                )
            }
            guard registerError == kDNSServiceErr_NoError,
                  let serviceRef else {
                throw Self.error(registerError)
            }
            let serviceQueueError = DNSServiceSetDispatchQueue(serviceRef, queue)
            guard serviceQueueError == kDNSServiceErr_NoError else {
                throw Self.error(serviceQueueError)
            }
            return Registration(
                serviceRef: serviceRef,
                addressRef: addressRef,
                callbackContexts: callbackContexts
            )
        } catch {
            queue.sync { DNSServiceRefDeallocate(addressRef) }
            if let serviceRef { DNSServiceRefDeallocate(serviceRef) }
            Self.release(callbackContexts)
            throw error
        }
    }

    private func handle(
        _ errorCode: Int32,
        serviceID: CmxIrohBonjourServiceID? = nil
    ) {
        if errorCode == kDNSServiceErr_NoError, let serviceID {
            publish(.registered(serviceID))
        } else if errorCode == kDNSServiceErr_PolicyDenied {
            publish(.policyDenied)
            stopRegistrations()
        } else if errorCode != kDNSServiceErr_NoError {
            publish(.failed(errorCode))
        }
    }

    private func stopRegistrations() {
        let previous = registrations
        registrations.removeAll(keepingCapacity: false)
        guard !previous.isEmpty else { return }
        queue.sync {
            for registration in previous {
                DNSServiceRefDeallocate(registration.serviceRef)
                DNSServiceRefDeallocate(registration.addressRef)
            }
        }
        for registration in previous {
            Self.release(registration.callbackContexts)
        }
    }

    private func publish(_ event: CmxIrohBonjourPublisherEvent) {
        for observer in observers.values { observer.yield(event) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private static func addressRecord(
        _ address: CmxIrohLANSocketAddress
    ) throws -> (type: UInt16, data: Data) {
        switch address.family {
        case .ipv4:
            var value = in_addr()
            guard address.ipAddress.withCString({ inet_pton(AF_INET, $0, &value) }) == 1 else {
                throw CmxIrohLANDiscoveryError.invalidSocketAddress
            }
            return (UInt16(kDNSServiceType_A), Data(bytes: &value, count: MemoryLayout.size(ofValue: value)))
        case .ipv6:
            var value = in6_addr()
            guard address.ipAddress.withCString({ inet_pton(AF_INET6, $0, &value) }) == 1 else {
                throw CmxIrohLANDiscoveryError.invalidSocketAddress
            }
            return (UInt16(kDNSServiceType_AAAA), Data(bytes: &value, count: MemoryLayout.size(ofValue: value)))
        }
    }

    private static func error(_ code: Int32) -> CmxIrohLANDiscoveryError {
        code == kDNSServiceErr_PolicyDenied ? .policyDenied : .serviceFailure(code)
    }

    private static func release(_ contexts: [UnsafeMutableRawPointer]) {
        for context in contexts {
            Unmanaged<CmxIrohBonjourRegisterCallbackBox>.fromOpaque(context).release()
        }
    }
}
