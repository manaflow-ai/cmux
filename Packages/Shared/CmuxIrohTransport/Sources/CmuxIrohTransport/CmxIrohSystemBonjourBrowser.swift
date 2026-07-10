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
) async -> Void

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
    Task {
        await handler(
            flags,
            interfaceIndex,
            errorCode,
            name,
            type,
            domain
        )
    }
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

    private static let defaultMaximumPendingResolves = 16
    private static let defaultResolveTimeout: TimeInterval = 5

    private let dnsService: any CmxIrohBonjourDNSService
    private let clock: any CmxIrohBonjourClock
    private let maximumPendingResolves: Int
    private let resolveTimeout: TimeInterval
    private var browseOperation: (any CmxIrohBonjourOperation)?
    private var browseToken: UUID?
    private var pending: [CmxIrohBonjourServiceID: PendingResolve] = [:]
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
        do {
            browseOperation = try dnsService.startBrowse(
                serviceType: CmxIrohLANAdvertisement.serviceType,
                domain: CmxIrohLANAdvertisement.domain
            ) { [weak self] flags, interfaceIndex, errorCode, name, type, domain in
                await self?.handleBrowse(
                    token: token,
                    flags: flags,
                    interfaceIndex: interfaceIndex,
                    errorCode: errorCode,
                    serviceName: name,
                    regtype: type,
                    domain: domain
                )
            }
        } catch let error as CmxIrohBonjourDNSServiceError {
            browseToken = nil
            publishError(error.code)
        } catch {
            browseToken = nil
            publishError(Int32(kDNSServiceErr_Unknown))
        }
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
            stopResolve(id)
            publish(.removed(id))
        }
    }

    private func startResolve(
        id: CmxIrohBonjourServiceID,
        regtype: String,
        domain: String
    ) {
        guard pending[id] == nil,
              pending.count < maximumPendingResolves else { return }
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
        } catch {
            publishError(Int32(kDNSServiceErr_Unknown))
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
    }

    private func stopOperations() {
        browseToken = nil
        let currentBrowseOperation = browseOperation
        browseOperation = nil
        let resolves = Array(pending.values)
        pending.removeAll(keepingCapacity: false)
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
