import Darwin
import Dispatch
import dnssd
import Foundation

private final class CmxIrohBonjourRegisterCallbackBox: Sendable {
    let handler: @Sendable (Int32) -> Void

    init(handler: @escaping @Sendable (Int32) -> Void) {
        self.handler = handler
    }
}

// Context ownership for both replies: register(_:) passes a box retained once
// (+1) as each registration's DNS-SD context and keeps it in Registration (or
// its failure path). The boxes are released only after DNSServiceRefDeallocate
// ran on `queue`, the queue that delivers these replies, so a reply always sees
// a live box.
private let cmxIrohBonjourServiceRegisterCallback: DNSServiceRegisterReply = {
    _, _, errorCode, _, _, _, context in
    // SAFETY: dnssd hands back the context pointer given to DNSServiceRegister.
    guard let context = unsafe context else { return }
    // SAFETY: the context is a live +1 box (context ownership above); the
    // unretained read does not change its count.
    unsafe Unmanaged<CmxIrohBonjourRegisterCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handler(errorCode)
}

private let cmxIrohBonjourRecordRegisterCallback: DNSServiceRegisterRecordReply = {
    _, _, _, errorCode, context in
    // SAFETY: dnssd hands back the context pointer given to DNSServiceRegisterRecord.
    guard let context = unsafe context else { return }
    // SAFETY: the context is a live +1 box (context ownership above); the
    // unretained read does not change its count.
    unsafe Unmanaged<CmxIrohBonjourRegisterCallbackBox>
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
    /// One advertisement's two live dnssd refs and the +1 contexts of their
    /// replies. stopRegistrations() deallocates and releases each exactly once.
    @safe
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
            observers.updateValue(continuation, forKey: id)
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

        // SAFETY: DNSServiceCreateConnection stores one shared-connection ref in addressRef.
        let addressCreateError = unsafe DNSServiceCreateConnection(&addressRef)
        // SAFETY: reads the ref DNSServiceCreateConnection stored, if any.
        guard addressCreateError == kDNSServiceErr_NoError,
              let addressRef = unsafe addressRef else {
            throw Self.error(addressCreateError)
        }
        // SAFETY: addressRef is the live ref created above.
        let addressQueueError = unsafe DNSServiceSetDispatchQueue(addressRef, queue)
        guard addressQueueError == kDNSServiceErr_NoError else {
            // SAFETY: the ref has no queue and no records, so nothing can call back;
            // it is deallocated once here.
            unsafe DNSServiceRefDeallocate(addressRef)
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
                // SAFETY: the +1 retain is the reply context; callbackContexts owns it from
                // here and is released once, on failure below or by stopRegistrations().
                let context = unsafe Unmanaged.passRetained(callback).toOpaque()
                // SAFETY: callbackContexts takes over the +1 just made (above).
                unsafe callbackContexts.append(context)
                let recordType = Self.addressRecordType(address)
                let recordData = address.addressBytes
                var recordRef: DNSRecordRef?
                // SAFETY: addressRef is live; dnssd copies the host target and the
                // recordData bytes (an A or AAAA address, 4 or 16, the length passed)
                // during the call; recordRef is owned by addressRef and freed with it.
                let registerError = unsafe DNSServiceRegisterRecord(
                    addressRef,
                    &recordRef,
                    DNSServiceFlags(kDNSServiceFlagsUnique),
                    advertisement.interfaceIndex,
                    advertisement.hostTarget,
                    recordType,
                    UInt16(clamping: kDNSServiceClass_IN),
                    UInt16(clamping: recordData.count),
                    recordData,
                    60,
                    cmxIrohBonjourRecordRegisterCallback,
                    context
                )
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
            // SAFETY: as for the record contexts above.
            let context = unsafe Unmanaged.passRetained(callback).toOpaque()
            // SAFETY: callbackContexts takes over the +1 just made (above).
            unsafe callbackContexts.append(context)
            let txtRecord = [UInt8](advertisement.txtRecord)
            // SAFETY: dnssd stores a ref in serviceRef and copies the strings and the
            // txtRecord bytes (txtRecord.count, the length passed; CmxIrohLANTXTRecord
            // bounds it below 65,536) during the call.
            let registerError = unsafe DNSServiceRegister(
                &serviceRef,
                DNSServiceFlags(kDNSServiceFlagsNoAutoRename),
                advertisement.interfaceIndex,
                advertisement.alias,
                CmxIrohLANAdvertisement.serviceType,
                CmxIrohLANAdvertisement.domain,
                advertisement.hostTarget,
                advertisement.port.bigEndian,
                UInt16(clamping: txtRecord.count),
                txtRecord,
                cmxIrohBonjourServiceRegisterCallback,
                context
            )
            // SAFETY: reads the ref DNSServiceRegister stored, if any.
            guard registerError == kDNSServiceErr_NoError,
                  let serviceRef = unsafe serviceRef else {
                throw Self.error(registerError)
            }
            // SAFETY: serviceRef is the live ref registered above.
            let serviceQueueError = unsafe DNSServiceSetDispatchQueue(serviceRef, queue)
            guard serviceQueueError == kDNSServiceErr_NoError else {
                throw Self.error(serviceQueueError)
            }
            // SAFETY: the registration takes over both live refs and every +1 context.
            return unsafe Registration(
                serviceRef: serviceRef,
                addressRef: addressRef,
                callbackContexts: callbackContexts
            )
        } catch {
            // SAFETY: addressRef is live and runs replies on `queue`; deallocating it
            // there means none of its replies runs after this.
            queue.sync { unsafe DNSServiceRefDeallocate(addressRef) }
            // SAFETY: a serviceRef here never got a queue, so it never called back; it is
            // deallocated once.
            if let serviceRef = unsafe serviceRef { unsafe DNSServiceRefDeallocate(serviceRef) }
            // SAFETY: no ref that could read these contexts is left (above).
            unsafe Self.release(callbackContexts)
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
                // SAFETY: each ref is live and was taken out of `registrations` once
                // above; deallocating on the reply queue ends its replies.
                unsafe DNSServiceRefDeallocate(registration.serviceRef)
                // SAFETY: as for serviceRef.
                unsafe DNSServiceRefDeallocate(registration.addressRef)
            }
        }
        for registration in previous {
            // SAFETY: the refs that could read these contexts are gone (above).
            unsafe Self.release(registration.callbackContexts)
        }
    }

    private func publish(_ event: CmxIrohBonjourPublisherEvent) {
        for observer in observers.values { observer.yield(event) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    /// The DNS record type for the address; its rdata is `addressBytes`, the
    /// network-order address inet_pton parsed (4 bytes for A, 16 for AAAA).
    private static func addressRecordType(_ address: CmxIrohLANSocketAddress) -> UInt16 {
        switch address.family {
        case .ipv4: UInt16(clamping: kDNSServiceType_A)
        case .ipv6: UInt16(clamping: kDNSServiceType_AAAA)
        }
    }

    private static func error(_ code: Int32) -> CmxIrohLANDiscoveryError {
        code == kDNSServiceErr_PolicyDenied ? .policyDenied : .serviceFailure(code)
    }

    /// Drops the +1 of each context; callers first end every ref that could read them.
    private static func release(_ contexts: [UnsafeMutableRawPointer]) {
        // SAFETY: each context is a +1 box released once (see the callers).
        for context in unsafe contexts {
            // SAFETY: as above.
            unsafe Unmanaged<CmxIrohBonjourRegisterCallbackBox>.fromOpaque(context).release()
        }
    }
}
