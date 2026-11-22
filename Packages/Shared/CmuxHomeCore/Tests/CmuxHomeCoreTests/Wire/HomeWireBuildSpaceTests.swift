import CMUXAuthCore
import CmuxHomeCoreTestSupport
import Foundation
import Testing
@testable import CmuxHomeCore

/// A dev build's `X-Cmux-Build-Space` header on the hosted `cmux.wire/1` client: every HTTP
/// request and the WebSocket upgrade carry it with a build space, none does without one, and a misconfigured
/// dev build (no usable tag) sends nothing at all.
@MainActor @Suite struct HomeWireBuildSpaceTests {
    let base = URL(string: "https://cloud-api-staging.cmux.dev")!
    let header = "X-Cmux-Build-Space"

    private func client(_ http: FakeWireHTTP, buildSpace: CMUXBuildSpaceState) -> HomeWireClient {
        HomeWireClient(baseURL: base, auth: .stack(FakeBearer()), http: http, buildSpace: buildSpace)
    }

    @Test func httpRequestsCarryTheBuildSpace() async throws {
        let http = FakeWireHTTP()
        let space = CMUXBuildSpaceState.dev(try #require(CMUXBuildSpace(devTag: "My_Tag 2")))
        _ = try await client(http, buildSpace: space).read("inbox.list", [:])
        _ = try await client(http, buildSpace: space).request("GET", "/v1/home/chief/brain", effect: .read)
        #expect(http.requests.count == 2)
        for request in http.requests {
            #expect(request.value(forHTTPHeaderField: header) == "dev:my-tag-2", "\(request)")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        }
    }

    @Test func httpRequestsWithoutABuildSpaceSendNoHeader() async throws {
        let http = FakeWireHTTP()
        _ = try await client(http, buildSpace: .nightly).read("inbox.list", [:])
        #expect(http.requests.count == 1)
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: header) == nil })
    }

    @Test func socketUpgradeCarriesTheBuildSpace() async throws {
        let space = CMUXBuildSpaceState.dev(try #require(CMUXBuildSpace(devTag: "feat-x")))
        let request = try await client(FakeWireHTTP(), buildSpace: space).socketRequest("/v1/wire/user", forceRefresh: false)
        #expect(request.url?.scheme == "wss")
        #expect(request.value(forHTTPHeaderField: header) == "dev:feat-x")
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.wire.v1")
    }

    @Test func socketUpgradeWithoutABuildSpaceSendsNoHeader() async throws {
        let request = try await client(FakeWireHTTP(), buildSpace: .nightly).socketRequest("/v1/wire/user", forceRefresh: false)
        #expect(request.value(forHTTPHeaderField: header) == nil)
    }

    @Test func wireHomeSourcePassesItsBuildSpaceToTheSockets() async throws {
        let sockets = FakeWireSockets()
        let space = CMUXBuildSpaceState.dev(try #require(CMUXBuildSpace(devTag: "feat-x")))
        let source = WireHomeSource(baseURL: base, auth: .stack(FakeBearer()), displayName: "Me", http: FakeWireHTTP(),
                                    sockets: sockets, clock: ContinuousClock(),
                                    fetchDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("wire-\(UUID().uuidString)"),
                                    buildSpace: space)
        let events = await source.events()
        _ = events
        await waitUntil { !sockets.dialed("/v1/wire/user").isEmpty }
        #expect(sockets.all.allSatisfy { $0.request.value(forHTTPHeaderField: header) == "dev:feat-x" })
        await source.shutdown()
    }

    @Test func aMisconfiguredDevBuildSendsNoRequestAndOpensNoSocket() async throws {
        let http = FakeWireHTTP()
        let refused = client(http, buildSpace: .misconfiguredDev(reason: "it has no tag"))
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await refused.read("inbox.list", [:]) }
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await refused.request("GET", "/v1/home/chief/brain", effect: .read) }
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await refused.socketRequest("/v1/wire/user", forceRefresh: false) }
        #expect(http.requests.isEmpty)
    }
}
