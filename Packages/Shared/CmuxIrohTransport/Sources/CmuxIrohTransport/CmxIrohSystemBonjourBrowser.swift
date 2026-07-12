@preconcurrency import Dispatch
import dnssd
import Foundation

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
