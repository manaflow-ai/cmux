import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CmuxEgress

/// The Swift egress gate lets through exactly what the Rust one does (cmux-tui/crates/cmux-egress's tests).
@Suite(.serialized) struct EgressTests {
    @Test func listedHostsAndPatternsPass() {
        #expect(Egress.verdict("cloud-api.cmux.dev") == .listed)
        #expect(Egress.verdict("https://Cloud-API.cmux.dev:443/v1/x?y") == .listed)
        #expect(Egress.verdict("acme.atlassian.net") == .listed)
        #expect(Egress.verdict("atlassian.net") == .unlisted)
        #expect(Egress.verdict("a.b.atlassian.net") == .unlisted)
        #expect(Egress.verdict("cmux-api-preview-42.debussy.workers.dev") == .listed)
        #expect(Egress.verdict("other-42.debussy.workers.dev") == .unlisted)
    }

    @Test func localAndReservedPass() {
        for host in ["127.0.0.1", "http://[::1]:8080/", "::1", "localhost", "app.localhost", "x.test", "example.com",
                     "printer.local"] {
            #expect(Egress.verdict(host) == .local, "\(host)")
        }
    }

    @Test func hostOfStripsSchemeUserPortAndDot() {
        #expect(Egress.hostOf("wss://user:pw@Relay.Example.org.:8443/path?q#f") == "relay.example.org")
        #expect(Egress.hostOf("[fe80::1]:22") == "fe80::1")
        #expect(Egress.hostOf("host.org") == "host.org")
    }

    @Test func namedHostsPassAndTheRestAreRefused() throws {
        Egress.setMode(.enforce)
        #expect(Egress.verdict("git.self-hosted-gate-test.org") == .unlisted)
        #expect(throws: Egress.Refused(host: "evil-gate-test.org", site: "EgressTests")) {
            try Egress.check("https://evil-gate-test.org/x", site: "EgressTests")
        }
        #expect(Egress.unlisted.contains("evil-gate-test.org EgressTests"))
        Egress.allowNamed("https://user@git.self-hosted-gate-test.org:8443/repo")
        #expect(Egress.verdict("git.self-hosted-gate-test.org") == .named)
        try Egress.check("git.self-hosted-gate-test.org", site: "EgressTests")
        Egress.setMode(.log)
        try Egress.check("https://evil-gate-test.org/x", site: "EgressTests")
    }

    @Test func modeParses() {
        #expect(Egress.Mode(parsing: " Enforce ") == .enforce)
        #expect(Egress.Mode(parsing: "0") == .off)
        #expect(Egress.Mode(parsing: "log") == .log)
        #expect(Egress.Mode(parsing: "maybe") == nil)
    }

    @Test func gatedSessionsPutTheGateFirstAndAddNothingToTheRequest() {
        let configuration = Egress.gated(.ephemeral, site: "EgressTests")
        #expect(configuration.protocolClasses?.first == EgressURLProtocol.self)
        #expect(Egress.gated(configuration, site: "EgressTests").protocolClasses?.filter { $0 == EgressURLProtocol.self }.count == 1)
        #expect(configuration.httpAdditionalHeaders == nil)
    }

    @Test func theProtocolTakesOnlyRefusedRequests() {
        Egress.setMode(.enforce)
        #expect(EgressURLProtocol.canInit(with: URLRequest(url: URL(string: "https://evil-gate-test.org/")!)))
        #expect(!EgressURLProtocol.canInit(with: URLRequest(url: URL(string: "https://cloud-api.cmux.dev/")!)))
        #expect(!EgressURLProtocol.canInit(with: URLRequest(url: URL(string: "file:///tmp/x")!)))
        Egress.setMode(.log)
        #expect(!EgressURLProtocol.canInit(with: URLRequest(url: URL(string: "https://evil-gate-test.org/")!)))
    }

    @Test func aRefusedRequestFailsBeforeItLeaves() async {
        Egress.setMode(.enforce)
        defer { Egress.setMode(.log) }
        let session = Egress.session(site: "EgressTests", configuration: .ephemeral)
        await #expect(throws: URLError.self) {
            _ = try await session.data(from: URL(string: "https://evil-gate-test.org/")!)
        }
    }

    @Test func aRefusedWebSocketGoesToTheInvalidHost() {
        Egress.setMode(.enforce)
        defer { Egress.setMode(.log) }
        let task = Egress.webSocketTask(in: .shared, with: URL(string: "wss://user@evil-gate-test.org/ws")!, site: "EgressTests")
        #expect(task.originalRequest?.url?.host == "egress-refused.invalid")
        #expect(task.originalRequest?.url?.user == nil)
        let allowed = Egress.webSocketTask(in: .shared, with: URL(string: "wss://cloud-api.cmux.dev/ws")!, site: "EgressTests")
        #expect(allowed.originalRequest?.url?.host == "cloud-api.cmux.dev")
    }

    #if canImport(Darwin)
    @Test func theSharedSessionRefusesToo() async {
        Egress.setMode(.enforce)
        defer { Egress.setMode(.log) }
        await #expect(throws: URLError.self) {
            _ = try await Egress.shared.data(from: URL(string: "https://evil-gate-test.org/")!)
        }
    }
    #endif
}
