import Foundation
import Testing
@testable import CmuxMobileBrowserStream

/// The forwarded port's stand-in for Private Network Access: a request reaches the
/// Mac's loopback only when it names the loopback with this port and comes from
/// the page's own site (or is a top-level page load), and only once its head is whole.
@Suite struct LoopbackRequestGateTests {
    func request(_ head: String, body: String = "") -> Data {
        Data((head.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    func passes(_ verdict: LoopbackRequestGate.Verdict) -> Bool {
        if case .forward = verdict { return true }
        return false
    }

    @Test func theDevAppsOwnRequestsPassWhole() {
        let gate = LoopbackRequestGate(port: 3000)
        let first = request("GET / HTTP/1.1\nHost: localhost:3000\nSec-Fetch-Site: none")
        #expect(gate.check(first) == .forward(first))
        let api = request("GET /api HTTP/1.1\nHost: 127.0.0.1:3000\nOrigin: http://localhost:3000\nSec-Fetch-Site: same-origin")
        #expect(gate.check(api) == .forward(api))
        // Another loopback port is the same site (a frontend calling its API).
        let post = request("POST /x HTTP/1.1\nHost: [::1]:3000\nOrigin: http://localhost:5173\nSec-Fetch-Site: same-site\nContent-Length: 4", body: "{}{}")
        #expect(gate.check(post) == .forward(post))
    }

    @Test func aHeadIsHeldUntilItIsWhole() {
        let gate = LoopbackRequestGate(port: 3000)
        let whole = request("GET /b HTTP/1.1\nHost: localhost:3000")
        #expect(gate.check(whole.prefix(10)) == .forward(Data()), "nothing reaches the Mac yet")
        #expect(gate.check(whole.dropFirst(10)) == .forward(whole))
    }

    @Test func aRebindingPageIsRefused() {
        #expect(!passes(LoopbackRequestGate(port: 3000).check(request("GET / HTTP/1.1\nHost: attacker.example:3000"))))
        #expect(!passes(LoopbackRequestGate(port: 3000).check(request("GET / HTTP/1.1\nHost: localhost:8080"))))
        #expect(!passes(LoopbackRequestGate(port: 3000).check(request("GET / HTTP/1.1\nAccept: */*"))))
    }

    @Test func anotherSitesRequestIsRefusedButAPageLoadFromThereIsNot() {
        let fetch = request("GET /api HTTP/1.1\nHost: localhost:3000\nSec-Fetch-Site: cross-site\nSec-Fetch-Mode: cors\nSec-Fetch-Dest: empty")
        #expect(!passes(LoopbackRequestGate(port: 3000).check(fetch)))
        let post = request("POST / HTTP/1.1\nHost: localhost:3000\nOrigin: https://evil.example\nContent-Length: 0")
        #expect(!passes(LoopbackRequestGate(port: 3000).check(post)))
        let null = request("POST / HTTP/1.1\nHost: localhost:3000\nOrigin: null\nContent-Length: 0")
        #expect(!passes(LoopbackRequestGate(port: 3000).check(null)))
        // A sign-in callback: another site sends the person's page here.
        let callback = request("GET /callback?code=1 HTTP/1.1\nHost: localhost:3000\nSec-Fetch-Site: cross-site\nSec-Fetch-Mode: navigate\nSec-Fetch-Dest: document")
        #expect(passes(LoopbackRequestGate(port: 3000).check(callback)))
    }

    @Test func everyRequestOnAKeptAliveConnectionIsChecked() {
        let gate = LoopbackRequestGate(port: 3000)
        // A body that looks like a request head is passed by its length, not read as one.
        let body = "GET / HTTP/1.1\r\nHost: evil\r\n\r\n"
        let first = request("POST /a HTTP/1.1\nHost: localhost:3000\nContent-Length: \(body.utf8.count)", body: body)
        #expect(gate.check(first) == .forward(first))
        #expect(!passes(gate.check(request("GET /b HTTP/1.1\nHost: localhost:3000\nSec-Fetch-Site: cross-site"))))
    }

    @Test func aWebSocketPassesOnlyAfterTheMacSwitches() {
        let gate = LoopbackRequestGate(port: 5173)
        let upgrade = request("GET /hmr HTTP/1.1\nHost: localhost:5173\nUpgrade: websocket\nConnection: Upgrade")
        #expect(gate.check(upgrade) == .forward(upgrade))
        #expect(!passes(gate.check(Data([0x81, 0x85]))), "nothing before the Mac's reply")

        let switched = LoopbackRequestGate(port: 5173)
        _ = switched.check(upgrade)
        switched.replied(Data("HTTP/1.1 101 Switching Protocols\r\n\r\n".utf8))
        #expect(switched.check(Data([0x81, 0x85, 1, 2, 3, 4])) == .forward(Data([0x81, 0x85, 1, 2, 3, 4])))

        // A 101 that arrives in two reads.
        let split = LoopbackRequestGate(port: 5173)
        _ = split.check(upgrade)
        split.replied(Data("HTTP/1.".utf8))
        split.replied(Data("1 101 Switching Protocols\r\n\r\n".utf8))
        #expect(split.check(Data([0x81, 0x80, 0, 0, 0, 0])) == .forward(Data([0x81, 0x80, 0, 0, 0, 0])))

        // Not switched: back to checked requests.
        let refused = LoopbackRequestGate(port: 5173)
        _ = refused.check(upgrade)
        refused.replied(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
        #expect(!passes(refused.check(request("GET / HTTP/1.1\nHost: evil.example"))))
    }

    @Test func notHTTPIsRefused() {
        #expect(!passes(LoopbackRequestGate(port: 6379).check(Data("PING\r\nCONFIG SET dir /tmp\r\n".utf8))))
        #expect(!passes(LoopbackRequestGate(port: 8443).check(Data([0x16, 0x03, 0x01, 0x02, 0x00]))), "TLS")
        #expect(!passes(LoopbackRequestGate(port: 3000).check(request("POST / HTTP/1.1\nHost: localhost:3000\nTransfer-Encoding: chunked"))))
    }
}
