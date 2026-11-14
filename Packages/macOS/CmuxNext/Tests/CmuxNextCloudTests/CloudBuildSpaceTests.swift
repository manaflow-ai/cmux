import CMUXAuthCore
@testable import CmuxNextCloud
import Foundation
import Testing

/// A tagged dev build carries `X-Cmux-Build-Space: dev:<slug>` on every request and WebSocket upgrade the Mac's
/// cloud clients send (CloudConfiguration.buildSpace); nightly and stable builds (no build space) send no such header.
@Suite(.serialized)
struct CloudBuildSpaceTests {
    static let header = "X-Cmux-Build-Space"
    static let space = CMUXBuildSpace(devTag: "My_Tag 2")
    static let base = URL(string: "https://cloud-api-staging.cmux.dev") ?? URL(fileURLWithPath: "/dev/null")

    nonisolated final class Recorder: URLProtocol {
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            Self.requests.append(request)
            let body = #"{"team":"team_aaaaaaaaaaaaaaaaaaaa","tenant":"t1","project":"p1","origin":"https://vm.invalid","mesh":"mesh_0123456789abcdefghjkmnpqrs","ipv4_cidr":"10.128.16.0/20"}"#
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test("The space is dev:<slug> of the build's tag")
    func spaceValue() {
        #expect(Self.space?.headerValue == "dev:my-tag-2")
    }

    @Test("CloudAPIClient sends the header on a Worker request with a build space, none without", arguments: [true, false])
    func workerClient(tagged: Bool) async throws {
        Recorder.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        let api = CloudAPIClient.workerMachines(baseURL: Self.base, accessToken: { "session" }, teamID: { "team_1" },
                                                session: URLSession(configuration: configuration),
                                                installToken: { "install" }, buildSpace: tagged ? Self.space : nil)
        _ = try await api.listNetworks()
        let request = try #require(Recorder.requests.first)
        #expect(request.value(forHTTPHeaderField: Self.header) == (tagged ? "dev:my-tag-2" : nil))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer install")
    }

    @Test("CloudOwnerAPIClient adds the header to its session's requests with a build space, none without", arguments: [true, false])
    func ownerClient(tagged: Bool) async throws {
        let owner = CloudOwnerAPIClient(baseURL: Self.base, accessToken: { "access" }, teamID: { "team_1" },
                                        buildSpace: tagged ? Self.space : nil)
        let request = await owner.authorized(URLRequest(url: Self.base.appendingPathComponent("v1/handoffs")), access: "access")
        #expect(request.value(forHTTPHeaderField: Self.header) == (tagged ? "dev:my-tag-2" : nil))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.value(forHTTPHeaderField: "x-cmux-team") == "team_1")
    }

    @Test("The wire ticket request and the /v1/wire/cloud upgrade carry the header with a build space, none without",
          arguments: [true, false])
    func machineWire(tagged: Bool) throws {
        let space = tagged ? Self.space : nil
        let ticket = CloudMachineWire.ticketRequest(apiBaseURL: Self.base, access: "access", buildSpace: space)
        #expect(ticket.url?.absoluteString == "https://cloud-api-staging.cmux.dev/v1/wire/ticket")
        #expect(ticket.value(forHTTPHeaderField: Self.header) == (tagged ? "dev:my-tag-2" : nil))
        let socket = try CloudMachineWire.socketRequest(apiBaseURL: Self.base, ticket: "t1", team: "team_1", version: "1.0",
                                                        buildSpace: space)
        #expect(socket.url?.absoluteString == "wss://cloud-api-staging.cmux.dev/v1/wire/cloud")
        #expect(socket.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.wire.v1, ticket.t1, team.team_1")
        #expect(socket.value(forHTTPHeaderField: Self.header) == (tagged ? "dev:my-tag-2" : nil))
    }

    @Test("A machine state socket's upgrade carries the header with a build space, none without", arguments: [true, false])
    func statePush(tagged: Bool) throws {
        let url = try #require(URL(string: "wss://cloud-api-staging.cmux.dev/v1/cloud/machines/vm_aaaaaaaaaaaaaaaaaaaa/state"))
        let request = CloudMachineStatePush.upgradeRequest(url: url, token: "access", team: "team_1",
                                                           buildSpace: tagged ? Self.space : nil)
        #expect(request.value(forHTTPHeaderField: Self.header) == (tagged ? "dev:my-tag-2" : nil))
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer access")
    }

    @Test("The install transport's POST and GET carry the header with a build space, none without", arguments: [true, false])
    func installTransport(tagged: Bool) throws {
        let transport = InstallHTTPTransport(baseURL: Self.base, buildSpace: tagged ? Self.space : nil)
        let post = transport.postRequest("v1/install/token", json: Data("{}".utf8), bearer: "b", headers: ["x-a": "1"])
        let get = try transport.getRequest("v1/me?x=1", bearer: nil, headers: [:])
        for request in [post, get] {
            #expect(request.value(forHTTPHeaderField: Self.header) == (tagged ? "dev:my-tag-2" : nil))
        }
        #expect(post.value(forHTTPHeaderField: "x-a") == "1")
        #expect(get.url?.absoluteString == "https://cloud-api-staging.cmux.dev/v1/me?x=1")
    }

    @Test("A configuration holds no build space until the composition root sets one")
    func configurationHoldsTheSpace() {
        var configuration = CloudConfiguration.unavailable
        configuration.buildSpace = Self.space
        #expect(configuration.buildSpace?.headerValue == "dev:my-tag-2")
        #expect(CloudConfiguration.unavailable.buildSpace == nil)
    }
}
