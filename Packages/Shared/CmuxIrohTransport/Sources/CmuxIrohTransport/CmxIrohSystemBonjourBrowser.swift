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

private struct CmxIrohBonjourDNSServiceError: Error, Sendable {
    let code: Int32
}

private final class CmxIrohBonjourBrowseCallbackBox: @unchecked Sendable {
    let handler: CmxIrohBonjourBrowseHandler

    init(handler: @escaping CmxIrohBonjourBrowseHandler) {
        self.handler = handler
    }
}

private struct CmxIrohBonjourRawBrowseEvent: Sendable {
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
private final class CmxIrohBonjourBrowseIngress: @unchecked Sendable {
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

private final class CmxIrohBonjourSystemDNSService: CmxIrohBonjourDNSService, @unchecked Sendable {
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

/// Low-level browser for the single declared cmux Iroh Bonjour service.
public actor CmxIrohSystemBonjourBrowser: CmxIrohBonjourBrowsing {
    private struct PendingResolve {
        let token: UUID
        let operation: any CmxIrohBonjourOperation
        let deadlineTask: Task<Void, Never>
    }

    private struct QueuedResolve: Sendable {
        let regtype: String
        let domain: String
    }

    private static let defaultMaximumPendingResolves = 16
    private static let defaultResolveTimeout: TimeInterval = 5

    private let dnsService: any CmxIrohBonjourDNSService
    private let clock: any CmxIrohBonjourClock
    private let maximumPendingResolves: Int
    private let resolveTimeout: TimeInterval
    private var browseOperation: (any CmxIrohBonjourOperation)?
    private var browseToken: UUID?
    private var browseIngress: CmxIrohBonjourBrowseIngress?
    private var browseEventTask: Task<Void, Never>?
    private var pending: [CmxIrohBonjourServiceID: PendingResolve] = [:]
    private var queued: [CmxIrohBonjourServiceID: QueuedResolve] = [:]
    private var queuedOrder: [CmxIrohBonjourServiceID] = []
    private var observers: [
        UUID: AsyncStream<CmxIrohBonjourBrowserEvent>.Continuation
    ] = [:]

    public init() {
        let queue = DispatchQueue(label: "dev.cmux.iroh.bonjour.browser")
        dnsService = CmxIrohBonjourSystemDNSService(queue: queue)
        clock = CmxIrohSystemBonjourClock()
        maximumPendingResolves = Self.defaultMaximumPendingResolves
        resolveTimeout = Self.defaultResolveTimeout
    }

    init(
        dnsService: any CmxIrohBonjourDNSService,
        clock: any CmxIrohBonjourClock,
        maximumPendingResolves: Int,
        resolveTimeout: TimeInterval
    ) {
        precondition(maximumPendingResolves > 0)
        precondition(resolveTimeout.isFinite && resolveTimeout > 0)
        self.dnsService = dnsService
        self.clock = clock
        self.maximumPendingResolves = maximumPendingResolves
        self.resolveTimeout = resolveTimeout
    }

    public func events() -> AsyncStream<CmxIrohBonjourBrowserEvent> {
        let id = UUID()
        let stream = AsyncStream(
            CmxIrohBonjourBrowserEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        ) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
        if browseOperation == nil { startBrowsing() }
        return stream
    }

    public func stop() {
        stopOperations()
        for observer in observers.values { observer.finish() }
        observers.removeAll(keepingCapacity: false)
    }

    private func startBrowsing() {
        let token = UUID()
        browseToken = token
        let (events, continuation) = AsyncStream.makeStream(
            of: CmxIrohBonjourRawBrowseEvent.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        let ingress = CmxIrohBonjourBrowseIngress(continuation: continuation)
        browseIngress = ingress
        browseEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                await self?.consumeBrowseEvent(token: token, event: event)
                ingress.consumed(event.key)
            }
        }
        do {
            browseOperation = try dnsService.startBrowse(
                serviceType: CmxIrohLANAdvertisement.serviceType,
                domain: CmxIrohLANAdvertisement.domain
            ) { flags, interfaceIndex, errorCode, name, type, domain in
                ingress.offer(
                    flags: flags,
                    interfaceIndex: interfaceIndex,
                    errorCode: errorCode,
                    serviceName: name,
                    regtype: type,
                    domain: domain
                )
            }
        } catch let error as CmxIrohBonjourDNSServiceError {
            ingress.finish()
            browseEventTask?.cancel()
            browseEventTask = nil
            browseIngress = nil
            browseToken = nil
            publishError(error.code)
        } catch {
            ingress.finish()
            browseEventTask?.cancel()
            browseEventTask = nil
            browseIngress = nil
            browseToken = nil
            publishError(Int32(kDNSServiceErr_Unknown))
        }
    }

    private func consumeBrowseEvent(
        token: UUID,
        event: CmxIrohBonjourRawBrowseEvent
    ) {
        handleBrowse(
            token: token,
            flags: event.flags,
            interfaceIndex: event.interfaceIndex,
            errorCode: event.errorCode,
            serviceName: event.serviceName,
            regtype: event.regtype,
            domain: event.domain
        )
    }

    private func handleBrowse(
        token: UUID,
        flags: DNSServiceFlags,
        interfaceIndex: UInt32,
        errorCode: Int32,
        serviceName: String?,
        regtype: String?,
        domain: String?
    ) {
        guard browseToken == token else { return }
        guard errorCode == kDNSServiceErr_NoError else {
            publishError(errorCode)
            if errorCode == kDNSServiceErr_PolicyDenied { stopOperations() }
            return
        }
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
        if added {
            startResolve(id: id, regtype: regtype, domain: domain)
        } else {
            removeQueuedResolve(id)
            stopResolve(id)
            publish(.removed(id))
        }
    }

    private func startResolve(
        id: CmxIrohBonjourServiceID,
        regtype: String,
        domain: String
    ) {
        guard pending[id] == nil, queued[id] == nil else { return }
        guard pending.count < maximumPendingResolves else {
            enqueueResolve(id: id, regtype: regtype, domain: domain)
            return
        }
        startResolveNow(id: id, regtype: regtype, domain: domain)
    }

    private func startResolveNow(
        id: CmxIrohBonjourServiceID,
        regtype: String,
        domain: String
    ) {
        let token = UUID()
        do {
            let operation = try dnsService.startResolve(
                id: id,
                regtype: regtype,
                domain: domain
            ) { [weak self] errorCode, interfaceIndex, host, port, txt in
                await self?.handleResolve(
                    id: id,
                    token: token,
                    errorCode: errorCode,
                    interfaceIndex: interfaceIndex,
                    hostTarget: host,
                    port: port,
                    txtRecord: txt
                )
            }
            let deadline = clock.now().addingTimeInterval(resolveTimeout)
            let clock = clock
            let deadlineTask = Task { [weak self] in
                do {
                    try await clock.sleep(until: deadline)
                    try Task.checkCancellation()
                    await self?.expireResolve(id: id, token: token)
                } catch {}
            }
            pending[id] = PendingResolve(
                token: token,
                operation: operation,
                deadlineTask: deadlineTask
            )
        } catch let error as CmxIrohBonjourDNSServiceError {
            publishError(error.code)
            drainQueuedResolves()
        } catch {
            publishError(Int32(kDNSServiceErr_Unknown))
            drainQueuedResolves()
        }
    }

    private func enqueueResolve(
        id: CmxIrohBonjourServiceID,
        regtype: String,
        domain: String
    ) {
        let maximumQueuedResolves = max(64, maximumPendingResolves * 4)
        guard queued.count < maximumQueuedResolves else { return }
        queued[id] = QueuedResolve(regtype: regtype, domain: domain)
        queuedOrder.append(id)
    }

    private func removeQueuedResolve(_ id: CmxIrohBonjourServiceID) {
        guard queued.removeValue(forKey: id) != nil else { return }
        queuedOrder.removeAll { $0 == id }
    }

    private func drainQueuedResolves() {
        while pending.count < maximumPendingResolves, !queuedOrder.isEmpty {
            let id = queuedOrder.removeFirst()
            guard let resolve = queued.removeValue(forKey: id) else { continue }
            startResolveNow(id: id, regtype: resolve.regtype, domain: resolve.domain)
        }
    }

    private func handleResolve(
        id: CmxIrohBonjourServiceID,
        token: UUID,
        errorCode: Int32,
        interfaceIndex: UInt32,
        hostTarget: String?,
        port: UInt16,
        txtRecord: Data?
    ) {
        guard pending[id]?.token == token else { return }
        defer { stopResolve(id, matching: token) }
        guard errorCode == kDNSServiceErr_NoError else {
            publishError(errorCode)
            if errorCode == kDNSServiceErr_PolicyDenied { stopOperations() }
            return
        }
        guard interfaceIndex == id.interfaceIndex,
              let hostTarget,
              hostTarget.utf8.count <= 253,
              let txtRecord,
              txtRecord.count <= CmxIrohLANTXTRecord.maximumEncodedSize else { return }
        publish(.resolved(
            id,
            CmxIrohBonjourResolvedService(
                serviceName: id.serviceName,
                hostTarget: hostTarget.lowercased(),
                interfaceIndex: interfaceIndex,
                port: port,
                txtRecord: txtRecord
            )
        ))
    }

    private func expireResolve(
        id: CmxIrohBonjourServiceID,
        token: UUID
    ) {
        stopResolve(id, matching: token)
    }

    private func stopResolve(
        _ id: CmxIrohBonjourServiceID,
        matching token: UUID? = nil
    ) {
        guard let resolve = pending[id],
              token == nil || resolve.token == token else { return }
        pending[id] = nil
        resolve.deadlineTask.cancel()
        resolve.operation.cancel()
        drainQueuedResolves()
    }

    private func stopOperations() {
        browseToken = nil
        browseIngress?.finish()
        browseIngress = nil
        browseEventTask?.cancel()
        browseEventTask = nil
        let currentBrowseOperation = browseOperation
        browseOperation = nil
        let resolves = Array(pending.values)
        pending.removeAll(keepingCapacity: false)
        queued.removeAll(keepingCapacity: false)
        queuedOrder.removeAll(keepingCapacity: false)
        for resolve in resolves { resolve.deadlineTask.cancel() }
        for resolve in resolves { resolve.operation.cancel() }
        currentBrowseOperation?.cancel()
    }

    private func publishError(_ code: Int32) {
        if code == kDNSServiceErr_PolicyDenied {
            publish(.policyDenied)
        } else {
            publish(.failed(code))
        }
    }

    private func publish(_ event: CmxIrohBonjourBrowserEvent) {
        for observer in observers.values { observer.yield(event) }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        if observers.isEmpty { stopOperations() }
    }
}
