@testable import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextRemoteFetch
import Foundation
import Testing

struct AgentPaneSourceIconTests {
    private actor Resolver: RemoteAddressResolving {
        var calls = 0
        let addresses: [RemoteAddress]

        init(_ addresses: [RemoteAddress] = [.v4([93, 184, 216, 34])]) { self.addresses = addresses }

        func resolve(_ host: String) async throws -> [RemoteAddress] {
            calls += 1
            // A second lookup would rebind the connection to loopback.
            return calls == 1 ? addresses : [.v4([127, 0, 0, 1])]
        }
    }

    private actor Transport: RemoteFetchTransport {
        var requests: [RemoteFetchRequest] = []
        let redirect: String?

        init(redirect: String? = nil) { self.redirect = redirect }

        func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
            requests.append(request)
            if let redirect { return RemoteFetchResponse(status: 302, headers: ["location": redirect], body: Data()) }
            return RemoteFetchResponse(status: 200, headers: [:], body: Data([1]))
        }
    }

    private func loader(_ resolver: Resolver, _ transport: Transport) -> AgentPaneSourceIcons {
        AgentPaneSourceIcons(fetch: GuardedRemoteFetch(maximumBytes: 1 << 20, timeout: .seconds(10),
                                                      accept: GuardedRemoteFetch.imageAccept,
                                                      resolver: resolver, transport: transport), decode: { $0 })
    }

    @Test(arguments: ["localhost", "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254", "[::1]", "[fe80::1]", "[fc00::1]"])
    func privateLiteralsNeverReachTransport(_ host: String) async throws {
        let transport = Transport()
        let url = try #require(URL(string: "https://\(host)/favicon.ico"))
        #expect(await loader(Resolver(), transport).data(at: url) == nil)
        #expect(await transport.requests.isEmpty)
    }

    @Test(arguments: [RemoteAddress.v4([10, 0, 0, 1]), .v4([127, 0, 0, 1]), .v4([169, 254, 169, 254])])
    func everyDNSAnswerMustBePublic(_ privateAddress: RemoteAddress) async throws {
        let transport = Transport()
        let resolver = Resolver([.v4([93, 184, 216, 34]), privateAddress])
        let url = try #require(URL(string: "https://private.example/favicon.ico"))
        #expect(await loader(resolver, transport).data(at: url) == nil)
        #expect(await transport.requests.isEmpty)
    }

    @Test func checkedDNSAddressIsPinnedWithoutASecondLookup() async throws {
        let transport = Transport()
        let resolver = Resolver()
        let url = try #require(URL(string: "https://rebind.example:8443/favicon.ico"))
        #expect(await loader(resolver, transport).data(at: url) == Data([1]))
        #expect(await resolver.calls == 1)
        let request = try #require(await transport.requests.first)
        #expect(request.address == .v4([93, 184, 216, 34]))
        #expect(request.host == "rebind.example")
        #expect(request.port == 8443)
    }

    @Test func defaultDecoderRefusesNonImageResponses() async throws {
        let transport = Transport()
        let icons = AgentPaneSourceIcons(fetch: GuardedRemoteFetch(maximumBytes: 1 << 20, timeout: .seconds(10),
                                                                 accept: GuardedRemoteFetch.imageAccept,
                                                                 resolver: Resolver(), transport: transport))
        let url = try #require(URL(string: "https://public.example/favicon.ico"))
        #expect(await icons.data(at: url) == nil)
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ["https://127.0.0.1/admin", "https://169.254.169.254/meta", "https://localhost/", "https://private.example/", "http://public.example/"])
    func redirectsAreCheckedBeforeConnecting(_ target: String) async throws {
        let transport = Transport(redirect: target)
        let url = try #require(URL(string: "https://public.example/favicon.ico"))
        #expect(await loader(Resolver(), transport).data(at: url) == nil)
        #expect(await transport.requests.count == 1)
        #expect(await transport.requests.allSatisfy { $0.address.isPublic })
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @MainActor @Test func originPreservesHTTPSAndPortAndRefusesHTTP() async throws {
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.sourceIconsBaseline = true
        var fetched: [URL] = []
        model.replyLinks.favicon = { url in fetched.append(url); return .icon(Data([1])) }
        let https = try #require(URL(string: "https://example.org:8443/docs?q=yes#part"))
        _ = await model.respond(to: .favicon(https))
        #expect(fetched.map(\.absoluteString) == ["https://example.org:8443/favicon.ico"])
        let http = try #require(URL(string: "http://example.org:8080/docs"))
        _ = await model.respond(to: .favicon(http))
        #expect(fetched.count == 1)
    }

    @MainActor @Test func layoutLabOverridesDocumentBaselineAndRefusalDoesNotStick() async throws {
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.sourceIconsBaseline = false
        var calls = 0
        model.replyLinks.favicon = { _ in calls += 1; return .icon(Data([1])) }
        let url = try #require(URL(string: "https://example.org/docs"))
        let refused = await model.respond(to: .favicon(url))
        #expect((refused["value"] as? [String: Any])?["disabled"] as? Bool == true)
        #expect(calls == 0)
        model.replyLinks.applySourceIconLayout(AgentPaneCustomization(layoutJSON: #"{"labs":{"sourceIcons":true}}"#))
        _ = await model.respond(to: .favicon(url))
        #expect(calls == 1)
        model.replyLinks.sourceIconsBaseline = true
        model.replyLinks.applySourceIconLayout(AgentPaneCustomization(layoutJSON: #"{"labs":{"sourceIcons":false}}"#))
        _ = await model.respond(to: .favicon(url))
        #expect(calls == 1)
        model.replyLinks.applySourceIconLayout(AgentPaneCustomization())
        _ = await model.respond(to: .favicon(url))
        #expect(calls == 2)
    }

    @Test func cancellationUsesTheSameValidatedRequestContract() throws {
        let url = try #require(URL(string: "https://example.org:8443/docs"))
        #expect(AgentPaneReplyRequest(method: "link.cancelFavicon", params: ["url": url.absoluteString]) == .cancelFavicon(url))
        #expect(AgentPaneReplyRequest(method: "link.cancelFavicon", params: ["url": "file:///etc/hosts"]) == nil)
        #expect(AgentPaneReplyRequest(method: "link.cancelFavicon", params: ["url": url.absoluteString, "otherPane": true]) == nil)
    }

}
