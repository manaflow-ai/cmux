import Foundation
import Testing
@testable import CmuxMobileBrowserStream

/// The forwarded port's stand-in for Private Network Access: a request reaches the
/// Mac's loopback only when it names the loopback with this port and comes from
/// the page's own site.
@Suite struct LoopbackRequestGateTests {
    func request(_ head: String, body: String = "") -> Data {
        Data((head.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    @Test func theDevAppsOwnRequestsPass() {
        var gate = LoopbackRequestGate(port: 3000)
        #expect(gate.check(request("GET / HTTP/1.1\nHost: localhost:3000\nSec-Fetch-Site: none")) == .pass)
        #expect(gate.check(request("GET /api HTTP/1.1\nHost: 127.0.0.1:3000\nOrigin: http://localhost:3000\nSec-Fetch-Site: same-origin")) == .pass)
        // Another loopback port is the same site (a frontend calling its API).
        #expect(gate.check(request("POST /x HTTP/1.1\nHost: [::1]:3000\nOrigin: http://localhost:5173\nSec-Fetch-Site: same-site\nContent-Length: 4", body: "{}{}")) == .pass)
    }

    @Test func aRebindingPageIsRefused() {
        var gate = LoopbackRequestGate(port: 3000)
        #expect(gate.check(request("GET / HTTP/1.1\nHost: attacker.example:3000")) != .pass)
        var otherPort = LoopbackRequestGate(port: 3000)
        #expect(otherPort.check(request("GET / HTTP/1.1\nHost: localhost:8080")) != .pass)
        var noHost = LoopbackRequestGate(port: 3000)
        #expect(noHost.check(request("GET / HTTP/1.1\nAccept: */*")) != .pass)
    }

    @Test func anotherSitesRequestIsRefused() {
        var crossSite = LoopbackRequestGate(port: 3000)
        #expect(crossSite.check(request("GET / HTTP/1.1\nHost: localhost:3000\nSec-Fetch-Site: cross-site")) != .pass)
        var origin = LoopbackRequestGate(port: 3000)
        #expect(origin.check(request("POST / HTTP/1.1\nHost: localhost:3000\nOrigin: https://evil.example\nContent-Length: 0")) != .pass)
    }

    @Test func everyRequestOnAKeptAliveConnectionIsChecked() {
        var gate = LoopbackRequestGate(port: 3000)
        // A body that looks like a request head is skipped by its length, not read as one.
        let first = request("POST /a HTTP/1.1\nHost: localhost:3000\nContent-Length: 30", body: "GET / HTTP/1.1\r\nHost: evil\r\n\r\n")
        #expect(gate.check(first) == .pass)
        // Split across reads.
        let second = request("GET /b HTTP/1.1\nHost: localhost:3000\nSec-Fetch-Site: cross-site")
        #expect(gate.check(second.prefix(10)) == .pass)
        #expect(gate.check(second.dropFirst(10)) != .pass)
    }

    @Test func aWebSocketAndTLSPassAsIs() {
        var socket = LoopbackRequestGate(port: 5173)
        #expect(socket.check(request("GET /hmr HTTP/1.1\nHost: localhost:5173\nUpgrade: websocket\nConnection: Upgrade")) == .pass)
        #expect(socket.check(Data([0x81, 0x85, 1, 2, 3, 4])) == .pass, "frames after the upgrade")
        var tls = LoopbackRequestGate(port: 8443)
        #expect(tls.check(Data([0x16, 0x03, 0x01, 0x02, 0x00])) == .pass)
    }

    @Test func notHTTPIsRefused() {
        var gate = LoopbackRequestGate(port: 6379)
        #expect(gate.check(Data("PING\r\nCONFIG SET dir /tmp\r\n\r\n".utf8)) != .pass)
    }
}
