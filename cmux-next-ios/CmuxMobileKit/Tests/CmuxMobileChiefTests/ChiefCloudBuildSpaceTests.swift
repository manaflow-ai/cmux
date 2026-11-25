import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// A dev build's cloud-api requests (HTTP, uploads to the Worker, and the `cmux.wire.v1` socket
/// upgrades of the Cloud Chief and the Mac replica) carry `X-Cmux-Build-Space`; a build without
/// one sends no such header, and a misconfigured dev build sends nothing. A presigned bucket upload never gets it.
@Suite(.serialized) struct ChiefCloudBuildSpaceTests {
    /// Records the headers of every request it sees and answers 200 `{}`.
    final class Recorder: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var seen: [URLRequest] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.withLock { Self.seen.append(request) }
            let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200,
                                           httpVersion: nil, headerFields: ["content-type": "application/json"])
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func take() -> [URLRequest] { lock.withLock { defer { seen = [] }; return seen } }
    }

    static func http(_ buildSpace: CMUXBuildSpace?) throws -> ChiefCloudHTTP {
        try http(state: buildSpace.map(CMUXBuildSpaceState.dev) ?? .nightly)
    }

    static func http(state buildSpace: CMUXBuildSpaceState) throws -> ChiefCloudHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        return ChiefCloudHTTP(base: try #require(URL(string: "https://cloud-api-staging.cmux.dev")),
                              accessToken: { _ in "token" }, session: URLSession(configuration: configuration),
                              buildSpace: buildSpace)
    }

    @Test func requestsCarryTheBuildSpace() throws {
        let http = try Self.http(CMUXBuildSpace(devTag: "My_Tag 2"))
        let request = try http.makeRequest("POST", "/v1/ops", token: "t", body: Data("{}".utf8), team: "team_1")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:my-tag-2")
        #expect(request.value(forHTTPHeaderField: "x-cmux-team") == "team_1")
        let plain = try Self.http(nil).makeRequest("GET", "/v1/read", token: "t")
        #expect(plain.value(forHTTPHeaderField: "X-Cmux-Build-Space") == nil)
    }

    @Test func socketUpgradesCarryTheBuildSpace() throws {
        let url = try #require(URL(string: "wss://cloud-api-staging.cmux.dev/v1/wire/host/h"))
        let request = try Self.http(CMUXBuildSpace(devTag: "feat-x")).socketRequest(url, token: "t")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:feat-x")
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.wire.v1")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer t")
        let plain = try Self.http(nil).socketRequest(url, token: "t")
        #expect(plain.value(forHTTPHeaderField: "X-Cmux-Build-Space") == nil)
    }

    @Test func sendCarriesTheBuildSpaceOnTheWire() async throws {
        _ = Recorder.take()
        _ = try await Self.http(CMUXBuildSpace(devTag: "feat-x")).send("POST", "/v1/ops", body: Data("{}".utf8))
        _ = try await Self.http(nil).send("GET", "/v1/read")
        let seen = Recorder.take()
        #expect(seen.count == 2)
        #expect(seen.first?.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:feat-x")
        #expect(seen.last?.value(forHTTPHeaderField: "X-Cmux-Build-Space") == nil)
    }

    @Test func onlyTheWorkersUploadsCarryTheBuildSpace() async throws {
        _ = Recorder.take()
        let http = try Self.http(CMUXBuildSpace(devTag: "feat-x"))
        let worker = try #require(URL(string: "https://cloud-api-staging.cmux.dev/v1/home/attachments/blob"))
        let bucket = try #require(URL(string: "https://bucket.example/obj?X-Amz-Signature=s"))
        _ = try await http.upload(worker, method: "PUT", headers: [:], body: Data("a".utf8), toWorker: true)
        _ = try await http.upload(bucket, method: "PUT", headers: [:], body: Data("a".utf8), toWorker: false)
        let seen = Recorder.take()
        #expect(seen.count == 2)
        #expect(seen.first?.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:feat-x")
        #expect(seen.last?.value(forHTTPHeaderField: "X-Cmux-Build-Space") == nil)
    }

    @Test func theConfigCarriesTheBuildSpaceToItsClient() throws {
        let space = CMUXBuildSpaceState(devBuild: true, devTag: "feat-x")
        let config = try #require(ChiefCloudConfig.current(environment: ["CMUX_MOBILE_CLOUD_API_BASE": "https://cloud-api-staging.cmux.dev"],
                                                           buildSpace: space))
        #expect(config.buildSpace == space)
        #expect(ChiefCloudConfig(baseURL: config.baseURL).buildSpace == .nightly)
    }

    @Test func aMisconfiguredDevBuildSendsNothing() async throws {
        _ = Recorder.take()
        let http = try Self.http(state: .misconfiguredDev(reason: "it has no tag"))
        #expect(throws: CMUXBuildSpaceError.self) { _ = try http.makeRequest("GET", "/v1/read", token: "t") }
        let url = try #require(URL(string: "wss://cloud-api-staging.cmux.dev/v1/wire/host/h"))
        #expect(throws: CMUXBuildSpaceError.self) { _ = try http.socketRequest(url, token: "t") }
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await http.send("POST", "/v1/ops", body: Data("{}".utf8)) }
        let worker = try #require(URL(string: "https://cloud-api-staging.cmux.dev/v1/home/attachments/blob"))
        await #expect(throws: CMUXBuildSpaceError.self) {
            _ = try await http.upload(worker, method: "PUT", headers: [:], body: Data("a".utf8), toWorker: true)
        }
        #expect(Recorder.take().isEmpty)
    }
}
