import Darwin
import CmuxCloud
import Foundation

/// Keeps a browser-visible loopback endpoint owned by cmux for the app's
/// lifetime. The SSH helper temporarily shares the listening socket; if it
/// exits, this lease answers queued and future requests with 503 instead of
/// allowing another local service to claim the old browser URL.
final class SSHTuiLoopbackListenerLease: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.cmuxterm.ssh-loopback-listener")
    private var unavailableSource: DispatchSourceRead?
    private var closed = false
    private var childGeneration: UInt64 = 0

    let port: UInt16
    var localURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.socketError() }
        guard Self.setCloseOnExec(fd) else {
            let error = Self.socketError()
            Darwin.close(fd)
            throw error
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, SOMAXCONN) == 0 else {
            let error = Self.socketError()
            Darwin.close(fd)
            throw error
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let error = Self.socketError()
            Darwin.close(fd)
            throw error
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0, bound.sin_port != 0 else {
            let error = Self.socketError()
            Darwin.close(fd)
            throw error
        }
        descriptor = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    /// Process.standardInput is mapped to descriptor 0 in the child. Keeping
    /// this descriptor open in the parent reserves the exact same socket.
    func makeChildInput() throws -> FileHandle {
        let childDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard childDescriptor >= 0 else { throw Self.socketError() }
        guard Self.setCloseOnExec(childDescriptor) else {
            let error = Self.socketError()
            Darwin.close(childDescriptor)
            throw error
        }
        return FileHandle(fileDescriptor: childDescriptor, closeOnDealloc: true)
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFD)
        return flags >= 0 && fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
    }

    func prepareForChild() -> UInt64 {
        // Drain any in-flight 503 accept handler before a new child starts
        // consuming from the shared socket's accept queue.
        queue.sync {
            lock.lock()
            childGeneration &+= 1
            let generation = childGeneration
            let source = unavailableSource
            unavailableSource = nil
            lock.unlock()
            source?.cancel()
            return generation
        }
    }

    func childDidStop(generation: UInt64) {
        queue.sync {
            lock.lock()
            guard !closed, childGeneration == generation, unavailableSource == nil else {
                lock.unlock()
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            unavailableSource = source
            lock.unlock()
            source.setEventHandler { [weak self] in self?.rejectPendingConnections(generation: generation) }
            source.resume()
        }
    }

    private func rejectPendingConnections(generation: UInt64) {
        while true {
            lock.lock()
            let isCurrent = !closed && childGeneration == generation && unavailableSource != nil
            lock.unlock()
            guard isCurrent else { return }
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            _ = withUnsafePointer(to: &noSignal) {
                Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
            }
            let response = Array("HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
            response.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(client, base.advanced(by: sent), bytes.count - sent, 0)
                    if count <= 0 { break }
                    sent += count
                }
            }
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
    }

    private static func socketError() -> NSError {
        let code = errno
        let message = String(localized: "ssh.tui.browserListener.operationFailed",
                             defaultValue: "Could not create or configure the managed SSH browser listener.")
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }

    deinit {
        lock.lock()
        closed = true
        let source = unavailableSource
        unavailableSource = nil
        lock.unlock()
        source?.cancel()
        Darwin.close(descriptor)
    }
}

/// Leases are intentionally retained until process exit because WebKit pages
/// may keep issuing requests after a provider or access model is retired.
actor SSHTuiLoopbackListenerLeaseRegistry {
    private struct Key: Hashable {
        let machineID: String
        let host: String
        let port: Int
    }

    private let maximumLeases = 64
    private var leases: [Key: SSHTuiLoopbackListenerLease] = [:]

    func lease(machineID: String, target: CloudPortForwardTarget) throws -> SSHTuiLoopbackListenerLease {
        let key = Key(machineID: machineID, host: target.host.lowercased(), port: target.port)
        if let existing = leases[key] { return existing }
        guard leases.count < maximumLeases else {
            throw CloudMachineLink.LinkError.failureMessage(String(
                localized: "ssh.tui.browserListener.endpointLimit",
                defaultValue: "The app's managed SSH browser endpoint limit has been reached."
            ))
        }
        let lease = try SSHTuiLoopbackListenerLease()
        leases[key] = lease
        return lease
    }
}
