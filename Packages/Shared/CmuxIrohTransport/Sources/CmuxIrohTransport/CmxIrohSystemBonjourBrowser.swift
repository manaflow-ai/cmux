@preconcurrency import Dispatch
import dnssd
import Foundation

private final class CmxIrohBonjourBrowseCallbackBox: @unchecked Sendable {
    let handler: @Sendable (
        DNSServiceFlags,
        UInt32,
        Int32,
        String?,
        String?,
        String?
    ) -> Void

    init(handler: @escaping @Sendable (
        DNSServiceFlags,
        UInt32,
        Int32,
        String?,
        String?,
        String?
    ) -> Void) {
        self.handler = handler
    }
}

private final class CmxIrohBonjourResolveCallbackBox: @unchecked Sendable {
    let handler: @Sendable (Int32, UInt32, String?, UInt16, Data?) -> Void

    init(handler: @escaping @Sendable (Int32, UInt32, String?, UInt16, Data?) -> Void) {
        self.handler = handler
    }
}

private let cmxIrohBonjourBrowseCallback: DNSServiceBrowseReply = {
    _, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain, context in
    guard let context else { return }
    let box = Unmanaged<CmxIrohBonjourBrowseCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
    box.handler(
        flags,
        interfaceIndex,
        errorCode,
        serviceName.map(String.init(cString:)),
        regtype.map(String.init(cString:)),
        replyDomain.map(String.init(cString:))
    )
}

private let cmxIrohBonjourResolveCallback: DNSServiceResolveReply = {
    _, _, interfaceIndex, errorCode, _, hostTarget, port, txtLength, txtRecord, context in
    guard let context else { return }
    let box = Unmanaged<CmxIrohBonjourResolveCallbackBox>
        .fromOpaque(context)
        .takeUnretainedValue()
    let data: Data?
    if txtLength == 0 {
        data = Data()
    } else if let txtRecord {
        data = Data(bytes: txtRecord, count: Int(txtLength))
    } else {
        data = nil
    }
    box.handler(
        errorCode,
        interfaceIndex,
        hostTarget.map(String.init(cString:)),
        UInt16(bigEndian: port),
        data
    )
}

/// Low-level browser for the single declared cmux Iroh Bonjour service.
public actor CmxIrohSystemBonjourBrowser: CmxIrohBonjourBrowsing {
    private struct PendingResolve {
        let ref: DNSServiceRef
        let context: UnsafeMutableRawPointer
    }

    private let queue = DispatchQueue(label: "dev.cmux.iroh.bonjour.browser")
    private var browseRef: DNSServiceRef?
    private var browseContext: UnsafeMutableRawPointer?
    private var pending: [CmxIrohBonjourServiceID: PendingResolve] = [:]
    private var observers: [
        UUID: AsyncStream<CmxIrohBonjourBrowserEvent>.Continuation
    ] = [:]

    public init() {}

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
        if browseRef == nil { startBrowsing() }
        return stream
    }

    public func stop() {
        stopOperations()
        for observer in observers.values { observer.finish() }
        observers.removeAll(keepingCapacity: false)
    }

    private func startBrowsing() {
        let callback = CmxIrohBonjourBrowseCallbackBox { [weak self] flags, interfaceIndex, errorCode, name, type, domain in
            Task {
                await self?.handleBrowse(
                    flags: flags,
                    interfaceIndex: interfaceIndex,
                    errorCode: errorCode,
                    serviceName: name,
                    regtype: type,
                    domain: domain
                )
            }
        }
        let context = Unmanaged.passRetained(callback).toOpaque()
        var ref: DNSServiceRef?
        let errorCode = DNSServiceBrowse(
            &ref,
            0,
            0,
            CmxIrohLANAdvertisement.serviceType,
            CmxIrohLANAdvertisement.domain,
            cmxIrohBonjourBrowseCallback,
            context
        )
        guard errorCode == kDNSServiceErr_NoError, let ref else {
            Unmanaged<CmxIrohBonjourBrowseCallbackBox>.fromOpaque(context).release()
            publishError(errorCode)
            return
        }
        let queueError = DNSServiceSetDispatchQueue(ref, queue)
        guard queueError == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(ref)
            Unmanaged<CmxIrohBonjourBrowseCallbackBox>.fromOpaque(context).release()
            publishError(queueError)
            return
        }
        browseRef = ref
        browseContext = context
    }

    private func handleBrowse(
        flags: DNSServiceFlags,
        interfaceIndex: UInt32,
        errorCode: Int32,
        serviceName: String?,
        regtype: String?,
        domain: String?
    ) {
        guard errorCode == kDNSServiceErr_NoError else {
            publishError(errorCode)
            if errorCode == kDNSServiceErr_PolicyDenied { stopOperations() }
            return
        }
        guard interfaceIndex != 0,
              let serviceName,
              !serviceName.isEmpty,
              serviceName.utf8.count <= 63,
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
        stopResolve(id)
        let callback = CmxIrohBonjourResolveCallbackBox { [weak self] errorCode, interfaceIndex, host, port, txt in
            Task {
                await self?.handleResolve(
                    id: id,
                    errorCode: errorCode,
                    interfaceIndex: interfaceIndex,
                    hostTarget: host,
                    port: port,
                    txtRecord: txt
                )
            }
        }
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
            publishError(errorCode)
            return
        }
        let queueError = DNSServiceSetDispatchQueue(ref, queue)
        guard queueError == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(ref)
            Unmanaged<CmxIrohBonjourResolveCallbackBox>.fromOpaque(context).release()
            publishError(queueError)
            return
        }
        pending[id] = PendingResolve(ref: ref, context: context)
    }

    private func handleResolve(
        id: CmxIrohBonjourServiceID,
        errorCode: Int32,
        interfaceIndex: UInt32,
        hostTarget: String?,
        port: UInt16,
        txtRecord: Data?
    ) {
        guard pending[id] != nil else { return }
        defer { stopResolve(id) }
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

    private func stopResolve(_ id: CmxIrohBonjourServiceID) {
        guard let resolve = pending.removeValue(forKey: id) else { return }
        queue.sync { DNSServiceRefDeallocate(resolve.ref) }
        Unmanaged<CmxIrohBonjourResolveCallbackBox>.fromOpaque(resolve.context).release()
    }

    private func stopOperations() {
        let resolves = Array(pending.values)
        pending.removeAll(keepingCapacity: false)
        let currentBrowseRef = browseRef
        browseRef = nil
        let currentBrowseContext = browseContext
        browseContext = nil
        guard currentBrowseRef != nil || !resolves.isEmpty else { return }
        queue.sync {
            for resolve in resolves { DNSServiceRefDeallocate(resolve.ref) }
            if let currentBrowseRef { DNSServiceRefDeallocate(currentBrowseRef) }
        }
        for resolve in resolves {
            Unmanaged<CmxIrohBonjourResolveCallbackBox>.fromOpaque(resolve.context).release()
        }
        if let currentBrowseContext {
            Unmanaged<CmxIrohBonjourBrowseCallbackBox>.fromOpaque(currentBrowseContext).release()
        }
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
    }
}
