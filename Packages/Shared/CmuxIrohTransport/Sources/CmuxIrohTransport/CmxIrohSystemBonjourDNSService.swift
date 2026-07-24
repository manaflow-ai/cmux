@preconcurrency import Dispatch
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
    private var enqueuedKeys: Set<CmxIrohBonjourRawBrowseEvent.Key> = []

    init(continuation: AsyncStream<CmxIrohBonjourRawBrowseEvent>.Continuation) {
        self.continuation = continuation
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

        let shouldYield = lock.withLock { enqueuedKeys.insert(event.key).inserted }
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
        data = Data(bytes: txtRecord, count: Int(txtLength))
    } else {
        data = nil
    }
    let host = hostTarget.map(String.init(cString:))
    let hostPort = UInt16(bigEndian: port)
    Task {
        await handler(errorCode, interfaceIndex, host, hostPort, data)
    }
}

private final class CmxIrohBonjourSystemOperation: CmxIrohBonjourOperation, @unchecked Sendable {
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
        state = State(ref: ref, context: context)
        self.queue = queue
        self.releaseContext = releaseContext
    }

    func cancel() {
        let current = lock.withLock {
            defer { state = nil }
            return state
        }
        guard let current else { return }
        queue.sync { DNSServiceRefDeallocate(current.ref) }
        releaseContext(current.context)
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
                    ? Int32(kDNSServiceErr_Unknown)
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
            context: context,
            queue: queue,
            releaseContext: { context in
                Unmanaged<CmxIrohBonjourBrowseCallbackBox>
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
                    ? Int32(kDNSServiceErr_Unknown)
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
            context: context,
            queue: queue,
            releaseContext: { context in
                Unmanaged<CmxIrohBonjourResolveCallbackBox>
                    .fromOpaque(context)
                    .release()
            }
        )
    }
}
