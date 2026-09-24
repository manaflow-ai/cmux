import CmuxMobileRPC
import CmuxMobileTunnel
import Darwin
import Foundation
import Testing
@testable import CmuxMobileShell

/// The paired-Mac "On iPhone" browser network against a fake Mac: which
/// destinations ride Mac lanes, which load directly, how the Mac's
/// listening ports are mirrored, and how the shared loopback is arbitrated.
@MainActor
@Suite(.serialized)
struct MobileMacBrowserNetworkTests {
    @Test(.timeLimit(.minutes(1))) func loopbackNamesRideMacLanesAndOtherHostsLoadDirectly() async throws {
        let mac = FakeMac(listing: MobileTunnelListeningPorts(ports: [:], allowsNonLoopbackHosts: false))
        let direct = RecordingDirect()
        let network = makeNetwork(mac: mac, direct: direct, registry: LoopbackPortRegistry())
        let proxyPort = try await network.prepare(loopbackPort: nil)

        let echoed = try await socksExchange(proxyPort: proxyPort, host: "app.localhost", port: 5173, payload: "ping")
        #expect(echoed.reply == 0x00)
        #expect(echoed.body == "ping<eof>")
        #expect(mac.opens == ["app.localhost:5173"])

        let other = try await socksExchange(proxyPort: proxyPort, host: "example.com", port: 443, payload: nil)
        #expect(other.reply == 0x00)
        #expect(direct.opens == ["example.com:443"])
        #expect(mac.opens == ["app.localhost:5173"])
        await network.stop()
    }

    @Test(.timeLimit(.minutes(1))) func everythingRidesTheMacWhenItAllowsOtherHosts() async throws {
        let mac = FakeMac(listing: MobileTunnelListeningPorts(ports: [:], allowsNonLoopbackHosts: true))
        let direct = RecordingDirect()
        let network = makeNetwork(mac: mac, direct: direct, registry: LoopbackPortRegistry())
        let proxyPort = try await network.prepare(loopbackPort: nil)
        _ = try await socksExchange(proxyPort: proxyPort, host: "intranet.example", port: 8080, payload: nil)
        #expect(mac.opens == ["intranet.example:8080"])
        #expect(direct.opens.isEmpty)
        await network.stop()
    }

    @Test(.timeLimit(.minutes(1))) func macRefusalsBecomeSocksReplies() async throws {
        let mac = FakeMac(listing: MobileTunnelListeningPorts(ports: [:], allowsNonLoopbackHosts: true))
        let network = makeNetwork(mac: mac, direct: RecordingDirect(), registry: LoopbackPortRegistry())
        let proxyPort = try await network.prepare(loopbackPort: nil)
        for (failure, code) in [
            (MobileTunnelOpenFailure.denied, UInt8(0x02)),
            (.refused, 0x05),
            (.unresolved, 0x04),
            (.busy, 0x01),
            (.unavailable, 0x01),
        ] {
            mac.failure = failure
            let result = try await socksExchange(proxyPort: proxyPort, host: "localhost", port: 3000, payload: nil)
            #expect(result.reply == code, "\(failure)")
        }
        await network.stop()
    }

    @Test(.timeLimit(.minutes(1))) func listedMacPortsAreMirroredOntoThePhone() async throws {
        let pagePort = try freePort()
        let apiPort = try freePort()
        let mac = FakeMac(listing: MobileTunnelListeningPorts(
            ports: [pagePort: "127.0.0.1", apiPort: "::1"], allowsNonLoopbackHosts: false
        ))
        let registry = LoopbackPortRegistry()
        let network = makeNetwork(mac: mac, direct: RecordingDirect(), registry: registry)
        _ = try await network.prepare(loopbackPort: pagePort)
        #expect(Set(network.forwards.keys) == [pagePort, apiPort])
        #expect(registry.entry(for: pagePort)?.owner == "mac:mac-1")

        let body = try await rawExchange(port: apiPort, payload: "hi")
        #expect(body == "hi<eof>")
        #expect(mac.opens == ["::1:\(apiPort)"])

        // The Mac stops listening on the API port: its forward goes away.
        mac.listing = MobileTunnelListeningPorts(ports: [pagePort: "127.0.0.1"], allowsNonLoopbackHosts: false)
        _ = try await network.prepare(loopbackPort: pagePort)
        #expect(Set(network.forwards.keys) == [pagePort])
        #expect(registry.entry(for: apiPort) == nil)
        await network.stop()
        #expect(registry.entry(for: pagePort) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func anotherComputersForwardGivesWayButProxiesDoNot() async throws {
        let taken = try freePort()
        let pinned = try freePort()
        let registry = LoopbackPortRegistry()
        var sshStopped = false
        registry.register(port: taken, owner: "ssh:other") { sshStopped = true }
        registry.register(port: pinned, owner: "ssh:other", pinned: true) {}
        let mac = FakeMac(listing: MobileTunnelListeningPorts(
            ports: [taken: "127.0.0.1", pinned: "127.0.0.1"], allowsNonLoopbackHosts: false
        ))
        let network = makeNetwork(mac: mac, direct: RecordingDirect(), registry: registry)
        _ = try await network.prepare(loopbackPort: taken)
        #expect(sshStopped)
        #expect(registry.entry(for: taken)?.owner == "mac:mac-1")
        #expect(network.forwards[pinned] == nil)
        #expect(registry.entry(for: pinned)?.owner == "ssh:other")
        await network.stop()
    }

    @Test(.timeLimit(.minutes(1))) func aPortTheSystemHoldsIsLeftToItsOwner() async throws {
        // Something else already listens on this phone port (on the
        // Simulator, the Mac's own server): the page reaches it directly.
        let holder = try TCPHolder()
        defer { holder.close() }
        let mac = FakeMac(listing: MobileTunnelListeningPorts(ports: [holder.port: "127.0.0.1"], allowsNonLoopbackHosts: false))
        let network = makeNetwork(mac: mac, direct: RecordingDirect(), registry: LoopbackPortRegistry())
        _ = try await network.prepare(loopbackPort: holder.port)
        #expect(network.forwards.isEmpty)
        await network.stop()
    }

    // MARK: Helpers

    private func makeNetwork(mac: FakeMac, direct: RecordingDirect, registry: LoopbackPortRegistry) -> MobileMacBrowserNetwork {
        MobileMacBrowserNetwork(
            macDeviceID: "mac-1",
            openLane: { host, port in try mac.open(host: host, port: port) },
            listPorts: { mac.listing },
            registry: registry,
            direct: direct
        )
    }

    private func socksExchange(proxyPort: Int, host: String, port: Int, payload: String?) async throws -> (reply: UInt8, body: String) {
        try await Task.detached { () throws -> (UInt8, String) in
            let fd = try RawSocket.connect(port: proxyPort)
            defer { Darwin.close(fd) }
            RawSocket.send(fd, [5, 1, 0])
            _ = RawSocket.receive(fd, count: 2)
            let name = Array(host.utf8)
            RawSocket.send(fd, [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)])
            let reply = RawSocket.receive(fd, count: 10)
            guard reply.count >= 2 else { return (0xFF, "") }
            guard let payload, reply[1] == 0 else { return (reply[1], "") }
            RawSocket.send(fd, Array(payload.utf8))
            shutdown(fd, SHUT_WR)
            return (reply[1], String(decoding: RawSocket.receiveAll(fd), as: UTF8.self))
        }.value
    }

    private func rawExchange(port: Int, payload: String) async throws -> String {
        try await Task.detached { () throws -> String in
            let fd = try RawSocket.connect(port: port)
            defer { Darwin.close(fd) }
            RawSocket.send(fd, Array(payload.utf8))
            shutdown(fd, SHUT_WR)
            return String(decoding: RawSocket.receiveAll(fd), as: UTF8.self)
        }.value
    }

    private func freePort() throws -> Int {
        let holder = try TCPHolder()
        defer { holder.close() }
        return holder.port
    }
}

/// A fake paired Mac: records lane opens and echoes over each lane.
final class FakeMac: @unchecked Sendable {
    private let lock = NSLock()
    private var _listing: MobileTunnelListeningPorts
    private var _opens: [String] = []
    private var _failure: MobileTunnelOpenFailure?

    init(listing: MobileTunnelListeningPorts) {
        _listing = listing
    }

    var listing: MobileTunnelListeningPorts {
        get { lock.withLock { _listing } }
        set { lock.withLock { _listing = newValue } }
    }

    var failure: MobileTunnelOpenFailure? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    var opens: [String] { lock.withLock { _opens } }

    func open(host: String, port: Int) throws -> any MobileTunnelLaneConnection {
        try lock.withLock {
            if let _failure { throw _failure }
            _opens.append("\(host):\(port)")
            return EchoLane()
        }
    }
}

final class EchoLane: MobileTunnelLaneConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?

    func receive(maximumByteCount: Int) async throws -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let next: Data?? = lock.withLock {
                if !queue.isEmpty { return .some(queue.removeFirst()) }
                waiter = continuation
                return .none
            }
            if case .some(let value) = next { continuation.resume(returning: value) }
        }
    }

    private func enqueue(_ data: Data?) {
        let waiter: CheckedContinuation<Data?, Never>? = lock.withLock {
            if let waiter = self.waiter {
                self.waiter = nil
                return waiter
            }
            queue.append(data)
            return nil
        }
        waiter?.resume(returning: data)
    }

    func send(_ data: Data) async throws { enqueue(data) }

    func finishSending() async {
        enqueue(Data("<eof>".utf8))
        enqueue(nil)
    }

    func close() async { enqueue(nil) }
}

/// A direct backend that records opens and hands back an idle stream.
final class RecordingDirect: SocksConnectBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _opens: [String] = []
    var opens: [String] { lock.withLock { _opens } }

    func open(host: String, port: Int) async throws -> any TunnelByteStream {
        lock.withLock { _opens.append("\(host):\(port)") }
        return IdleStream()
    }

    final class IdleStream: TunnelByteStream, @unchecked Sendable {
        func read() async throws -> Data? { nil }
        func write(_ data: Data) async throws {}
        func finishWriting() async {}
        func close() async {}
    }
}

/// Holds a loopback TCP port open.
final class TCPHolder: @unchecked Sendable {
    let port: Int
    private let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func close() {
        Darwin.close(fd)
    }
}

enum RawSocket {
    static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    static func send(_ fd: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    static func receive(_ fd: Int32, count: Int) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < count {
            let read = Darwin.read(fd, &buffer, min(buffer.count, count - result.count))
            if read <= 0 { break }
            result += buffer[0..<read]
        }
        return result
    }

    static func receiveAll(_ fd: Int32) -> [UInt8] {
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = Darwin.read(fd, &buffer, buffer.count)
            if read <= 0 { break }
            result += buffer[0..<read]
        }
        return result
    }
}
