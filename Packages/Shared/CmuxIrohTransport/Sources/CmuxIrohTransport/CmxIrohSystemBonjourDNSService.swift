import Dispatch
import dnssd
import Foundation
import os

typealias CmxIrohBonjourBrowseHandler = @Sendable (
    DNSServiceFlags,
    UInt32,
    Int32,
    String?,
    String?,
    String?
) -> Void

typealias CmxIrohBonjourResolveHandler = @Sendable (
    Int32,
    UInt32,
    String?,
    UInt16,
    Data?
) async -> Void

protocol CmxIrohBonjourOperation: Sendable {
    func cancel()
}

protocol CmxIrohBonjourDNSService: Sendable {
    func startBrowse(
        serviceType: String,
        domain: String,
        handler: @escaping CmxIrohBonjourBrowseHandler
    ) throws -> any CmxIrohBonjourOperation

    func startResolve(
        id: CmxIrohBonjourServiceID,
        regtype: String,
        domain: String,
        handler: @escaping CmxIrohBonjourResolveHandler
    ) throws -> any CmxIrohBonjourOperation
}

protocol CmxIrohBonjourClock: Sendable {
    func now() -> Date
    func sleep(until deadline: Date) async throws
}

struct CmxIrohSystemBonjourClock: CmxIrohBonjourClock {
    func now() -> Date { Date() }

    func sleep(until deadline: Date) async throws {
        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else { return }
        try await Task<Never, Never>.sleep(for: .seconds(delay))
    }
}

struct CmxIrohBonjourDNSServiceError: Error, Sendable {
    let code: Int32
}

private final class CmxIrohBonjourBrowseCallbackBox: Sendable {
    let handler: CmxIrohBonjourBrowseHandler

    init(handler: @escaping CmxIrohBonjourBrowseHandler) {
        self.handler = handler
    }
}

struct CmxIrohBonjourRawBrowseEvent: Sendable {
    enum Key: Hashable, Sendable {
        case service(CmxIrohBonjourServiceID, added: Bool)
        case error(Int32)
    }

    let key: Key
    let flags: DNSServiceFlags
    let interfaceIndex: UInt32
    let errorCode: Int32
    let serviceName: String?
    let regtype: String?
    let domain: String?
}

/// Validates and coalesces the synchronous DNS-SD callback before it reaches
/// Swift concurrency. One bounded stream consumer replaces one unbounded Task
/// per unauthenticated LAN record.
final class CmxIrohBonjourBrowseIngress: Sendable {
    private let continuation: AsyncStream<CmxIrohBonjourRawBrowseEvent>.Continuation
    private let serviceNameAllowlist: Set<String>?
    private let enqueuedKeys = OSAllocatedUnfairLock<Set<CmxIrohBonjourRawBrowseEvent.Key>>(initialState: [])

    init(
        continuation: AsyncStream<CmxIrohBonjourRawBrowseEvent>.Continuation,
        serviceNameAllowlist: Set<String>? = nil
    ) {
        self.continuation = continuation
        self.serviceNameAllowlist = serviceNameAllowlist
    }

    func offer(
        flags: DNSServiceFlags,
        interfaceIndex: UInt32,
        errorCode: Int32,
        serviceName: String?,
        regtype: String?,
        domain: String?
    ) {
        let event: CmxIrohBonjourRawBrowseEvent
        if errorCode != kDNSServiceErr_NoError {
            event = CmxIrohBonjourRawBrowseEvent(
                key: .error(errorCode),
                flags: flags,
                interfaceIndex: interfaceIndex,
                errorCode: errorCode,
                serviceName: nil,
                regtype: nil,
                domain: nil
            )
        } else {
            guard interfaceIndex != 0,
                  let serviceName,
                  CmxIrohLANRendezvousAliasGenerator.isCanonicalAlias(serviceName),
                  let regtype,
                  let domain,
                  regtype == "\(CmxIrohLANAdvertisement.serviceType).",
                  domain == CmxIrohLANAdvertisement.domain else { return }
            let id = CmxIrohBonjourServiceID(
                serviceName: serviceName,
                interfaceIndex: interfaceIndex
            )
            let added = flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
            event = CmxIrohBonjourRawBrowseEvent(
                key: .service(id, added: added),
                flags: flags,
                interfaceIndex: interfaceIndex,
                errorCode: errorCode,
                serviceName: serviceName,
                regtype: regtype,
                domain: domain
            )
        }

        if case let .service(id, _) = event.key,
           let serviceNameAllowlist,
           !serviceNameAllowlist.contains(id.serviceName) {
            return
        }
        let key = event.key
        let shouldYield = enqueuedKeys.withLock { $0.insert(key).inserted }
        guard shouldYield else { return }
        if case .dropped = continuation.yield(event) {
            consumed(event.key)
        }
    }

    func consumed(_ key: CmxIrohBonjourRawBrowseEvent.Key) {
        enqueuedKeys.withLock { _ = $0.remove(key) }
    }

    func finish() {
        continuation.finish()
        enqueuedKeys.withLock { $0.removeAll(keepingCapacity: false) }
    }
}

private final class CmxIrohBonjourResolveCallbackBox: Sendable {
    let handler: CmxIrohBonjourResolveHandler

    init(handler: @escaping CmxIrohBonjourResolveHandler) {
        self.handler = handler
    }
}

private let cmxIrohBonjourBrowseCallback: DNSServiceBrowseReply = {
    _, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain, context in
    guard let context else { return }
    let handler = Unmanaged<CmxIrohBonjourBrowseCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handler
    let name = serviceName.map(String.init(cString:))
    let type = regtype.map(String.init(cString:))
    let domain = replyDomain.map(String.init(cString:))
    handler(flags, interfaceIndex, errorCode, name, type, domain)
}

private let cmxIrohBonjourResolveCallback: DNSServiceResolveReply = {
    _, _, interfaceIndex, errorCode, _, hostTarget, port, txtLength, txtRecord, context in
    guard let context else { return }
    let handler = Unmanaged<CmxIrohBonjourResolveCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handler
    let data: Data?
    if txtLength == 0 {
        data = Data()
    } else if let txtRecord {
        data = Data(bytes: txtRecord, count: Int(clamping: txtLength))
    } else {
        data = nil
    }
    let host = hostTarget.map(String.init(cString:))
    let hostPort = UInt16(bigEndian: port)
    Task {
        await handler(errorCode, interfaceIndex, host, hostPort, data)
    }
}

/// A DNS-SD service reference (an `OpaquePointer` to the daemon connection).
private struct CmxIrohDNSServiceHandle: @unchecked Sendable { // crash-allow: the ref is used only on the DNS-SD queue it was bound to (DNSServiceSetDispatchQueue) and CmxIrohBonjourSystemOperation hands it out of its lock exactly once, to deallocate it on that queue
    let ref: DNSServiceRef
}

private final class CmxIrohBonjourSystemOperation: CmxIrohBonjourOperation {
    private struct Registration: Sendable {
        let handle: CmxIrohDNSServiceHandle
        let releaseCallback: @Sendable () -> Void
    }

    private let queue: DispatchQueue
    private let registration: OSAllocatedUnfairLock<Registration?>

    /// - Parameter releaseCallback: Balances the retain that keeps the callback box alive as the
    ///   C context; runs once, after the ref is deallocated, so no callback can still reach it.
    init(
        ref: DNSServiceRef,
        queue: DispatchQueue,
        releaseCallback: @escaping @Sendable () -> Void
    ) {
        self.queue = queue
        registration = OSAllocatedUnfairLock(
            initialState: Registration(
                handle: CmxIrohDNSServiceHandle(ref: ref),
                releaseCallback: releaseCallback
            )
        )
    }

    func cancel() {
        let current = registration.withLock { registration in
            defer { registration = nil }
            return registration
        }
        guard let current else { return }
        queue.sync { DNSServiceRefDeallocate(current.handle.ref) }
        current.releaseCallback()
    }
}

final class CmxIrohBonjourSystemDNSService: CmxIrohBonjourDNSService {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func startBrowse(
        serviceType: String,
        domain: String,
        handler: @escaping CmxIrohBonjourBrowseHandler
    ) throws -> any CmxIrohBonjourOperation {
        let callback = CmxIrohBonjourBrowseCallbackBox(handler: handler)
        let context = Unmanaged.passRetained(callback).toOpaque()
        var ref: DNSServiceRef?
        let errorCode = DNSServiceBrowse(
            &ref,
            0,
            0,
            serviceType,
            domain,
            cmxIrohBonjourBrowseCallback,
            context
        )
        guard errorCode == kDNSServiceErr_NoError, let ref else {
            Unmanaged<CmxIrohBonjourBrowseCallbackBox>.fromOpaque(context).release()
            throw CmxIrohBonjourDNSServiceError(
                code: errorCode == kDNSServiceErr_NoError
                    ? Int32(clamping: kDNSServiceErr_Unknown)
                    : errorCode
            )
        }
        let queueError = DNSServiceSetDispatchQueue(ref, queue)
        guard queueError == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(ref)
            Unmanaged<CmxIrohBonjourBrowseCallbackBox>.fromOpaque(context).release()
            throw CmxIrohBonjourDNSServiceError(code: queueError)
        }
        return CmxIrohBonjourSystemOperation(
            ref: ref,
            queue: queue,
            releaseCallback: { Unmanaged.passUnretained(callback).release() }
        )
    }

    func startResolve(
        id: CmxIrohBonjourServiceID,
        regtype: String,
        domain: String,
        handler: @escaping CmxIrohBonjourResolveHandler
    ) throws -> any CmxIrohBonjourOperation {
        let callback = CmxIrohBonjourResolveCallbackBox(handler: handler)
        let context = Unmanaged.passRetained(callback).toOpaque()
        var ref: DNSServiceRef?
        let errorCode = DNSServiceResolve(
            &ref,
            0,
            id.interfaceIndex,
            id.serviceName,
            regtype,
            domain,
            cmxIrohBonjourResolveCallback,
            context
        )
        guard errorCode == kDNSServiceErr_NoError, let ref else {
            Unmanaged<CmxIrohBonjourResolveCallbackBox>.fromOpaque(context).release()
            throw CmxIrohBonjourDNSServiceError(
                code: errorCode == kDNSServiceErr_NoError
                    ? Int32(clamping: kDNSServiceErr_Unknown)
                    : errorCode
            )
        }
        let queueError = DNSServiceSetDispatchQueue(ref, queue)
        guard queueError == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(ref)
            Unmanaged<CmxIrohBonjourResolveCallbackBox>.fromOpaque(context).release()
            throw CmxIrohBonjourDNSServiceError(code: queueError)
        }
        return CmxIrohBonjourSystemOperation(
            ref: ref,
            queue: queue,
            releaseCallback: { Unmanaged.passUnretained(callback).release() }
        )
    }
}
