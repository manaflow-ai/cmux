import Darwin
import Dispatch
import Foundation
import OwlBrowserCore

final class MachPortRendezvousServer: @unchecked Sendable {
    nonisolated(unsafe) private static var sharedInstance: MachPortRendezvousServer?
    private static let sharedLock = NSLock()

    static func shared() throws -> MachPortRendezvousServer {
        try sharedLock.withLock {
            if let sharedInstance {
                return sharedInstance
            }
            let created = try MachPortRendezvousServer()
            sharedInstance = created
            return created
        }
    }

    private static let nullPort = mach_port_t(0)
    private static let maximumRequestCount = 16
    private static let bootstrapName = "org.chromium.ContentShell.MachPortRendezvousServer.\(getpid())"
    private static let requestMessageID: mach_msg_id_t = 1_836_218_998
    private static let responseMessageID: mach_msg_id_t = 1_297_242_710

    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "minimal-browser.mach-port-rendezvous")
    private var registeredPorts: [pid_t: MachRendezvousPort] = [:]
    private var serverPort: mach_port_t = nullPort
    private var source: DispatchSourceMachReceive?

    private init() throws {
        var port: mach_port_t = Self.nullPort
        let allocateResult = mach_port_allocate(
            mach_task_self_,
            mach_port_right_t(MACH_PORT_RIGHT_RECEIVE),
            &port
        )
        guard allocateResult == KERN_SUCCESS else {
            throw OwlBrowserError.launch("mach_port_allocate rendezvous server failed with result \(allocateResult)")
        }

        let insertResult = mach_port_insert_right(
            mach_task_self_,
            port,
            port,
            mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)
        )
        guard insertResult == KERN_SUCCESS else {
            mach_port_mod_refs(
                mach_task_self_,
                port,
                mach_port_right_t(MACH_PORT_RIGHT_RECEIVE),
                -1
            )
            throw OwlBrowserError.launch("mach_port_insert_right rendezvous server failed with result \(insertResult)")
        }

        var bootstrapPort: mach_port_t = Self.nullPort
        let bootstrapResult = task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrapPort)
        guard bootstrapResult == KERN_SUCCESS else {
            mach_port_mod_refs(
                mach_task_self_,
                port,
                mach_port_right_t(MACH_PORT_RIGHT_SEND),
                -1
            )
            mach_port_mod_refs(
                mach_task_self_,
                port,
                mach_port_right_t(MACH_PORT_RIGHT_RECEIVE),
                -1
            )
            throw OwlBrowserError.launch("task_get_special_port(TASK_BOOTSTRAP_PORT) failed with result \(bootstrapResult)")
        }
        let result = Self.bootstrapName.withCString { name in
            bootstrap_register(bootstrapPort, name, port)
        }
        guard result == KERN_SUCCESS else {
            mach_port_mod_refs(
                mach_task_self_,
                port,
                mach_port_right_t(MACH_PORT_RIGHT_SEND),
                -1
            )
            mach_port_mod_refs(
                mach_task_self_,
                port,
                mach_port_right_t(MACH_PORT_RIGHT_RECEIVE),
                -1
            )
            throw OwlBrowserError.launch("bootstrap_register \(Self.bootstrapName) failed with result \(result)")
        }
        serverPort = port
        let source = DispatchSource.makeMachReceiveSource(port: port, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleAvailableRequests()
        }
        source.resume()
        self.source = source
    }

    func makeKey() -> UInt32 {
        condition.withLock {
            var key: UInt32 = 0
            repeat {
                key = UInt32.random(in: 1...UInt32.max)
            } while registeredPorts.values.contains(where: { $0.key == key })
            return key
        }
    }

    func register(receiveRight: mach_port_t, key: UInt32, processID: pid_t) {
        let exitWatcher = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: queue)
        exitWatcher.setEventHandler { [weak self] in
            self?.unregister(processID: processID)
        }
        condition.withLock {
            registeredPorts[processID] = MachRendezvousPort(
                key: key,
                receiveRight: receiveRight,
                exitWatcher: exitWatcher
            )
            condition.broadcast()
        }
        exitWatcher.resume()
    }

    func unregister(processID: pid_t) {
        condition.withLock {
            guard let port = registeredPorts.removeValue(forKey: processID) else {
                return
            }
            port.exitWatcher.cancel()
            port.destroy()
            condition.broadcast()
        }
    }

    private func handleAvailableRequests() {
        for _ in 0..<Self.maximumRequestCount {
            guard handleRequest() else {
                return
            }
        }
    }

    @discardableResult
    private func handleRequest() -> Bool {
        let requestSize = MemoryLayout<mach_msg_header_t>.size + MemoryLayout<mach_msg_audit_trailer_t>.size
        let rawRequest = UnsafeMutableRawPointer.allocate(
            byteCount: requestSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer {
            rawRequest.deallocate()
        }
        rawRequest.initializeMemory(as: UInt8.self, repeating: 0, count: requestSize)
        let header = rawRequest.bindMemory(to: mach_msg_header_t.self, capacity: 1)
        header.pointee.msgh_size = mach_msg_size_t(requestSize)
        header.pointee.msgh_local_port = serverPort

        let options = mach_msg_option_t(
            UInt32(MACH_RCV_MSG) |
            UInt32(MACH_RCV_TIMEOUT) |
            Self.machReceiveTrailerType(UInt32(MACH_MSG_TRAILER_FORMAT_0)) |
            Self.machReceiveTrailerElements(UInt32(MACH_RCV_TRAILER_AUDIT))
        )
        let result = mach_msg(
            header,
            options,
            0,
            mach_msg_size_t(requestSize),
            serverPort,
            0,
            Self.nullPort
        )
        if result == MACH_RCV_TIMED_OUT {
            return false
        }
        guard result == KERN_SUCCESS else {
            return false
        }

        var shouldDestroyRequest = true
        defer {
            if shouldDestroyRequest {
                mach_msg_destroy(header)
            }
        }

        guard header.pointee.msgh_id == Self.requestMessageID,
              header.pointee.msgh_size == mach_msg_size_t(MemoryLayout<mach_msg_header_t>.size) else {
            return true
        }

        let trailer = rawRequest
            .advanced(by: MemoryLayout<mach_msg_header_t>.size)
            .bindMemory(to: mach_msg_audit_trailer_t.self, capacity: 1)
            .pointee
        let processID = pid_t(trailer.msgh_audit.val.5)
        guard let port = takePort(for: processID) else {
            return true
        }

        let sendResult = sendReply(replyPort: header.pointee.msgh_remote_port, port: port)
        if sendResult == KERN_SUCCESS {
            shouldDestroyRequest = false
        }
        return true
    }

    private func takePort(for processID: pid_t) -> MachRendezvousPort? {
        let deadline = Date().addingTimeInterval(5)
        return condition.withLock {
            while registeredPorts[processID] == nil {
                guard condition.wait(until: deadline) else {
                    return nil
                }
            }
            let port = registeredPorts.removeValue(forKey: processID)
            port?.exitWatcher.cancel()
            return port
        }
    }

    private func sendReply(replyPort: mach_port_t, port: MachRendezvousPort) -> mach_msg_return_t {
        let baseSize = MemoryLayout<mach_msg_base_t>.size
        let descriptorSize = MemoryLayout<mach_msg_port_descriptor_t>.size
        let keySize = MemoryLayout<UInt32>.size
        let additionalDataSizeFieldSize = MemoryLayout<UInt64>.size
        let responseSize = alignToUInt32(baseSize + descriptorSize + keySize + additionalDataSizeFieldSize)
        let rawResponse = UnsafeMutableRawPointer.allocate(
            byteCount: responseSize,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer {
            rawResponse.deallocate()
        }
        rawResponse.initializeMemory(as: UInt8.self, repeating: 0, count: responseSize)

        let message = rawResponse.bindMemory(to: mach_msg_base_t.self, capacity: 1)
        message.pointee.header.msgh_bits = mach_msg_bits_t(
            UInt32(MACH_MSG_TYPE_MOVE_SEND_ONCE) | UInt32(MACH_MSGH_BITS_COMPLEX)
        )
        message.pointee.header.msgh_size = mach_msg_size_t(responseSize)
        message.pointee.header.msgh_remote_port = replyPort
        message.pointee.header.msgh_local_port = Self.nullPort
        message.pointee.header.msgh_id = Self.responseMessageID
        message.pointee.body.msgh_descriptor_count = 1

        let descriptor = rawResponse
            .advanced(by: baseSize)
            .bindMemory(to: mach_msg_port_descriptor_t.self, capacity: 1)
        descriptor.pointee.name = port.receiveRight
        descriptor.pointee.disposition = mach_msg_type_name_t(MACH_MSG_TYPE_MOVE_RECEIVE)
        descriptor.pointee.type = mach_msg_descriptor_type_t(MACH_MSG_PORT_DESCRIPTOR)

        var key = port.key
        withUnsafeBytes(of: &key) { bytes in
            rawResponse.advanced(by: baseSize + descriptorSize).copyMemory(
                from: bytes.baseAddress!,
                byteCount: bytes.count
            )
        }
        var emptyAdditionalDataSize: UInt64 = 0
        withUnsafeBytes(of: &emptyAdditionalDataSize) { bytes in
            rawResponse.advanced(by: baseSize + descriptorSize + keySize).copyMemory(
                from: bytes.baseAddress!,
                byteCount: bytes.count
            )
        }

        return mach_msg(
            rawResponse.bindMemory(to: mach_msg_header_t.self, capacity: 1),
            mach_msg_option_t(MACH_SEND_MSG),
            mach_msg_size_t(responseSize),
            0,
            Self.nullPort,
            MACH_MSG_TIMEOUT_NONE,
            Self.nullPort
        )
    }

    private func alignToUInt32(_ value: Int) -> Int {
        (value + 3) & ~3
    }

    private static func machReceiveTrailerType(_ value: UInt32) -> UInt32 {
        (value & 0xf) << 28
    }

    private static func machReceiveTrailerElements(_ value: UInt32) -> UInt32 {
        (value & 0xf) << 24
    }
}

private struct MachRendezvousPort {
    let key: UInt32
    let receiveRight: mach_port_t
    let exitWatcher: DispatchSourceProcess

    func destroy() {
        mach_port_mod_refs(
            mach_task_self_,
            receiveRight,
            mach_port_right_t(MACH_PORT_RIGHT_RECEIVE),
            -1
        )
    }
}

private extension NSCondition {
    func withLock<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}

@_silgen_name("bootstrap_register")
private func bootstrap_register(
    _ bootstrapPort: mach_port_t,
    _ serviceName: UnsafePointer<CChar>,
    _ serverPort: mach_port_t
) -> kern_return_t
