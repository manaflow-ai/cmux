import Foundation
import Testing
@testable import CmuxNextRemoteLocalhost

/// The literal loopback rule and the proxy head parser.
struct RoutingTests {
    /// A token is lowercase hex of the requested length; a negative length used to trap.
    @Test func randomTokensAreHexOfTheRequestedLength() {
        let token = ProxyCredential.randomToken(bytes: 16)
        #expect(token.count == 32)
        #expect(token.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(token != ProxyCredential.randomToken(bytes: 16))
        #expect(ProxyCredential.randomToken(bytes: 0).isEmpty)
        #expect(ProxyCredential.randomToken(bytes: -1).isEmpty)
    }

    @Test func loopbackHostsAreDecidedWithoutDNS() {
        for host in ["localhost", "LocalHost", "localhost.", "app.localhost", "a-b.c.localhost", "127.0.0.1",
                     "127.12.34.56", "::1", "[::1]", "::ffff:127.0.0.1"] {
            #expect(LoopbackHost(host).isLoopback, "\(host) goes to the tab's machine")
        }
        for host in ["", "example.com", "localhost.example.com", "127.0.0.1.nip.io", "localtest.me", "10.0.0.1",
                     "192.168.1.1", "169.254.169.254", "8.8.8.8", "0.0.0.0", "::", "[::ffff:10.0.0.1]", "fe80::1",
                     "127.1", "0x7f.0.0.1", "2130706433", "-a.localhost", "a..localhost", "a_b.localhost",
                     "[localhost]", "localhost:80", "0127.0.0.1"] {
            #expect(!LoopbackHost(host).isLoopback, "\(host) goes direct from this Mac")
        }
        #expect(LoopbackHost(url: URL(string: "http://localhost:5173/src/main.ts")!)?.isLoopback == true)
        #expect(LoopbackHost(url: URL(string: "ws://[::1]:24678/")!)?.isLoopback == true)
        #expect(LoopbackHost(url: URL(string: "https://github.com/")!)?.isLoopback == false)
    }

    @Test func connectHeadsParse() throws {
        let raw = Data("CONNECT localhost:5173 HTTP/1.1\r\nHost: localhost:5173\r\nProxy-Authorization: Basic eDp5\r\n\r\nTLS".utf8)
        let (head, used) = try ProxyRequestHead.parse(raw)
        #expect(head.kind == .connect)
        #expect(head.host == "localhost")
        #expect(head.port == 5173)
        #expect(head.proxyAuthorization == "Basic eDp5")
        #expect(raw.count - used == 3, "the bytes after the head are tunnel payload")

        let (v6, _) = try ProxyRequestHead.parse(Data("CONNECT [::1]:24678 HTTP/1.1\r\n\r\n".utf8))
        #expect(v6.host == "::1")
        #expect(v6.port == 24678)
    }

    @Test func absoluteFormHeadsBecomeOriginFormWithConnectionClose() throws {
        let raw = Data((
            "POST http://localhost:3000/api/items?limit=2 HTTP/1.1\r\nHost: localhost:3000\r\n"
                + "Proxy-Connection: keep-alive\r\nProxy-Authorization: Basic c2VjcmV0\r\nConnection: keep-alive\r\n"
                + "Content-Length: 4\r\n\r\nbody"
        ).utf8)
        let (head, used) = try ProxyRequestHead.parse(raw)
        #expect(head.kind == .forward)
        #expect(head.host == "localhost")
        #expect(head.port == 3000)
        #expect(head.path == "/api/items?limit=2")
        #expect(raw.count - used == 4)
        let origin = String(decoding: head.originHead(), as: UTF8.self)
        #expect(origin.hasPrefix("POST /api/items?limit=2 HTTP/1.1\r\n"))
        #expect(origin.contains("Host: localhost:3000\r\n"))
        #expect(origin.contains("Content-Length: 4\r\n"))
        #expect(!origin.lowercased().contains("proxy-"), "proxy credentials never reach the origin")
        #expect(origin.hasSuffix("Connection: close\r\n\r\n"))
        #expect(origin.components(separatedBy: "Connection:").count == 2, "one Connection field")

        let (plain, _) = try ProxyRequestHead.parse(Data("GET http://127.0.0.1/ HTTP/1.1\r\n\r\n".utf8))
        #expect(plain.port == 80)
        #expect(plain.path == "/")
    }

    @Test func badHeadsAreRefused() {
        #expect(throws: ProxyRequestHead.ParseError.incomplete) { try ProxyRequestHead.parse(Data("GET http://localhost/ HTTP/1.1\r\n".utf8)) }
        #expect(throws: ProxyRequestHead.ParseError.tooLarge) {
            try ProxyRequestHead.parse(Data(("GET http://localhost/ HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8))
        }
        #expect(throws: ProxyRequestHead.ParseError.unsupportedScheme("https")) {
            try ProxyRequestHead.parse(Data("GET https://localhost/ HTTP/1.1\r\n\r\n".utf8))
        }
        #expect(throws: (any Error).self) { try ProxyRequestHead.parse(Data("CONNECT localhost HTTP/1.1\r\n\r\n".utf8)) }
        #expect(throws: (any Error).self) { try ProxyRequestHead.parse(Data("CONNECT localhost:0 HTTP/1.1\r\n\r\n".utf8)) }
        #expect(throws: (any Error).self) { try ProxyRequestHead.parse(Data("GET / HTTP/2\r\n\r\n".utf8)) }
    }

    @Test func credentialsCompareInConstantTime() {
        #expect(ProxyCredential.constantTimeEqual("abc", "abc"))
        #expect(!ProxyCredential.constantTimeEqual("abc", "abd"))
        #expect(!ProxyCredential.constantTimeEqual("abc", "abcd"))
        let token = ProxyCredential.randomToken(bytes: 32)
        #expect(token.count == 64)
        #expect(token != ProxyCredential.randomToken(bytes: 32))
    }

    @Test func onlyARouteCredentialFindsItsRoute() {
        let proxy = RemoteLocalhostProxy(secret: "s3cret")
        let buildBox = proxy.credential(for: "reg-build-box", route: .init(machineName: "build-box", opener: FailingOpener(.refused)))
        let other = proxy.credential(for: "reg-other", route: .init(machineName: "other", opener: FailingOpener(.refused)))
        #expect(buildBox.username != other.username)
        #expect(proxy.route(forAuthorization: buildBox.basicAuthorization)?.machineName == "build-box")
        #expect(proxy.route(forAuthorization: other.basicAuthorization)?.machineName == "other")
        let wrong = ProxyCredential(username: buildBox.username, password: "guess")
        #expect(proxy.route(forAuthorization: wrong.basicAuthorization) == nil)
        #expect(proxy.route(forAuthorization: nil) == nil)
        #expect(proxy.route(forAuthorization: "Bearer x") == nil)
        let again = proxy.credential(for: "reg-build-box", route: .init(machineName: "build-box", opener: FailingOpener(.refused)))
        #expect(again == buildBox, "a machine keeps its user name for the launch")
        proxy.removeRoute(for: "reg-build-box")
        #expect(proxy.route(forAuthorization: buildBox.basicAuthorization) == nil)
    }
}

struct FailingOpener: LoopbackTunnelOpening {
    let failure: LoopbackTunnelFailure
    init(_ failure: LoopbackTunnelFailure) { self.failure = failure }
    func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
        throw failure
    }
}
