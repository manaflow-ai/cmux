import Dispatch
import dnssd
import Foundation

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

private final class CmxIrohBonjourBrowseCallbackBox: @unchecked Sendable {
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
final class CmxIrohBonjourBrowseIngress: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<CmxIrohBonjourRawBrowseEvent>.Continuation
    private let serviceNameAllowlist: Set<String>?
    private var enqueuedKeys: Set<CmxIrohBonjourRawBrowseEvent.Key> = []

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

        let shouldYield = lock.withLock {
            if case let .service(id, _) = event.key,
               let serviceNameAllowlist,
               !serviceNameAllowlist.contains(id.serviceName) {
                return false
            }
            return enqueuedKeys.insert(event.key).inserted
        }
        guard shouldYield else { return }
        if case .dropped = continuation.yield(event) {
            consumed(event.key)
        }
    }

    func consumed(_ key: CmxIrohBonjourRawBrowseEvent.Key) {
        lock.withLock { _ = enqueuedKeys.remove(key) }
    }

    func finish() {
        continuation.finish()
        lock.withLock { enqueuedKeys.removeAll(keepingCapacity: false) }
    }
}

private final class CmxIrohBonjourResolveCallbackBox: @unchecked Sendable {
    let handler: CmxIrohBonjourResolveHandler

    init(handler: @escaping CmxIrohBonjourResolveHandler) {
        self.handler = handler
    }
}

// Context ownership for both replies: startBrowse and startResolve pass a box
// retained once (+1) as the DNS-SD context. The box is released only by
// CmxIrohBonjourSystemOperation.cancel(), after DNSServiceRefDeallocate ran on
// the queue that delivers these replies, or on a start failure before any reply
// can run. A reply therefore always sees a live box.
private let cmxIrohBonjourBrowseCallback: DNSServiceBrowseReply = {
    _, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain, context in
    // SAFETY: dnssd hands back the context pointer given to DNSServiceBrowse.
    guard let context = unsafe context else { return }
    // SAFETY: the context is a live +1 browse box (context ownership above); the
    // unretained read does not change its count.
    let handler = unsafe Unmanaged<CmxIrohBonjourBrowseCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handler
    // SAFETY: dnssd's strings are NUL-terminated and valid during this reply;
    // String(cString:) copies each before the reply returns.
    let name = unsafe serviceName.map(String.init(cString:))
    // SAFETY: as for serviceName.
    let type = unsafe regtype.map(String.init(cString:))
    // SAFETY: as for serviceName.
    let domain = unsafe replyDomain.map(String.init(cString:))
    handler(flags, interfaceIndex, errorCode, name, type, domain)
}

private let cmxIrohBonjourResolveCallback: DNSServiceResolveReply = {
    _, _, interfaceIndex, errorCode, _, hostTarget, port, txtLength, txtRecord, context in
    // SAFETY: dnssd hands back the context pointer given to DNSServiceResolve.
    guard let context = unsafe context else { return }
    // SAFETY: the context is a live +1 resolve box (context ownership above); the
    // unretained read does not change its count.
    let handler = unsafe Unmanaged<CmxIrohBonjourResolveCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handler
    let data: Data?
    if txtLength == 0 {
        data = Data()
    } else {
        // SAFETY: a non-nil txtRecord points to txtLength readable bytes during this
        // reply; Data(bytes:count:) copies them before the reply returns.
        data = unsafe txtRecord.map { unsafe Data(bytes: $0, count: Int(clamping: txtLength)) }
    }
    // SAFETY: hostTarget is NUL-terminated and valid during this reply; String(cString:) copies it.
    let host = unsafe hostTarget.map(String.init(cString:))
    let hostPort = UInt16(bigEndian: port)
    Task {
        await handler(errorCode, interfaceIndex, host, hostPort, data)
    }
}

// A dnssd ref and its +1 context box (context ownership above). cancel() takes
// both out of `state` under the lock, so they are released exactly once.
@safe
private final class CmxIrohBonjourSystemOperation: CmxIrohBonjourOperation, @unchecked Sendable {
    @safe
    private struct State {
        let ref: DNSServiceRef
        let context: UnsafeMutableRawPointer
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private let releaseContext: (UnsafeMutableRawPointer) -> Void
    private var state: State?

    init(
        ref: DNSServiceRef,
        context: UnsafeMutableRawPointer,
        queue: DispatchQueue,
        releaseContext: @escaping (UnsafeMutableRawPointer) -> Void
    ) {
        // SAFETY: the operation takes over the live ref and the +1 context from its
        // start call; cancel() is the only place that releases them.
        state = unsafe State(ref: ref, context: context)
        self.queue = queue
        self.releaseContext = releaseContext
    }

    func cancel() {
        let current = lock.withLock {
            defer { state = nil }
            return state
        }
        guard let current else { return }
        // SAFETY: the ref is live and taken out of `state` once; deallocating it on the
        // reply queue means no reply runs after this returns.
        queue.sync { unsafe DNSServiceRefDeallocate(current.ref) }
        // SAFETY: no reply can read the context any more (above); this drops its +1 once.
        unsafe releaseContext(current.context)
    }
}

final class CmxIrohBonjourSystemDNSService: CmxIrohBonjourDNSService, @unchecked Sendable {
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
        // SAFETY: the +1 retain is the reply context; each path below either releases it
        // once or hands it to the operation (context ownership above).
        let context = unsafe Unmanaged.passRetained(callback).toOpaque()
        var ref: DNSServiceRef?
        // SAFETY: DNSServiceBrowse stores a ref in `ref` and reads the NUL-terminated
        // copies of serviceType and domain Swift makes for this call.
        let errorCode = unsafe DNSServiceBrowse(
            &ref,
            0,
            0,
            serviceType,
            domain,
            cmxIrohBonjourBrowseCallback,
            context
        )
        // SAFETY: reads the ref DNSServiceBrowse stored, if any.
        guard errorCode == kDNSServiceErr_NoError, let ref = unsafe ref else {
            // SAFETY: without a ref no reply can run; this drops the +1 once.
            unsafe Unmanaged<CmxIrohBonjourBrowseCallbackBox>.fromOpaque(context).release()
            throw CmxIrohBonjourDNSServiceError(
                code: errorCode == kDNSServiceErr_NoError
                    ? Int32(clamping: kDNSServiceErr_Unknown)
                    : errorCode
            )
        }
        // SAFETY: `ref` is the live ref DNSServiceBrowse returned.
        let queueError = unsafe DNSServiceSetDispatchQueue(ref, queue)
        guard queueError == kDNSServiceErr_NoError else {
            // SAFETY: the ref has no queue, so no reply ran or can run; it is
            // deallocated once here.
            unsafe DNSServiceRefDeallocate(ref)
            // SAFETY: as above; this drops the +1 once.
            unsafe Unmanaged<CmxIrohBonjourBrowseCallbackBox>.fromOpaque(context).release()
            throw CmxIrohBonjourDNSServiceError(code: queueError)
        }
        // SAFETY: the operation takes over the live ref and the +1 context.
        return unsafe CmxIrohBonjourSystemOperation(
            ref: ref,
            context: context,
            queue: queue,
            releaseContext: { context in
                // SAFETY: cancel() calls this once, after the ref was deallocated.
                unsafe Unmanaged<CmxIrohBonjourBrowseCallbackBox>
                    .fromOpaque(context)
                    .release()
            }
        )
    }

    func startResolve(
        id: CmxIrohBonjourServiceID,
        regtype: String,
        domain: String,
        handler: @escaping CmxIrohBonjourResolveHandler
    ) throws -> any CmxIrohBonjourOperation {
        let callback = CmxIrohBonjourResolveCallbackBox(handler: handler)
        // SAFETY: the +1 retain is the reply context; each path below either releases it
        // once or hands it to the operation (context ownership above).
        let context = unsafe Unmanaged.passRetained(callback).toOpaque()
        var ref: DNSServiceRef?
        // SAFETY: DNSServiceResolve stores a ref in `ref` and reads the NUL-terminated
        // copies of the service name, regtype and domain Swift makes for this call.
        let errorCode = unsafe DNSServiceResolve(
            &ref,
            0,
            id.interfaceIndex,
            id.serviceName,
            regtype,
            domain,
            cmxIrohBonjourResolveCallback,
            context
        )
        // SAFETY: reads the ref DNSServiceResolve stored, if any.
        guard errorCode == kDNSServiceErr_NoError, let ref = unsafe ref else {
            // SAFETY: without a ref no reply can run; this drops the +1 once.
            unsafe Unmanaged<CmxIrohBonjourResolveCallbackBox>.fromOpaque(context).release()
            throw CmxIrohBonjourDNSServiceError(
                code: errorCode == kDNSServiceErr_NoError
                    ? Int32(clamping: kDNSServiceErr_Unknown)
                    : errorCode
            )
        }
        // SAFETY: `ref` is the live ref DNSServiceResolve returned.
        let queueError = unsafe DNSServiceSetDispatchQueue(ref, queue)
        guard queueError == kDNSServiceErr_NoError else {
            // SAFETY: the ref has no queue, so no reply ran or can run; it is
            // deallocated once here.
            unsafe DNSServiceRefDeallocate(ref)
            // SAFETY: as above; this drops the +1 once.
            unsafe Unmanaged<CmxIrohBonjourResolveCallbackBox>.fromOpaque(context).release()
            throw CmxIrohBonjourDNSServiceError(code: queueError)
        }
        // SAFETY: the operation takes over the live ref and the +1 context.
        return unsafe CmxIrohBonjourSystemOperation(
            ref: ref,
            context: context,
            queue: queue,
            releaseContext: { context in
                // SAFETY: cancel() calls this once, after the ref was deallocated.
                unsafe Unmanaged<CmxIrohBonjourResolveCallbackBox>
                    .fromOpaque(context)
                    .release()
            }
        )
    }
}
