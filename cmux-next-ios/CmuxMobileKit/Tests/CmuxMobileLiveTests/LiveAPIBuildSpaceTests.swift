import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxMobileLive

/// A dev build's cmux-mobile-api requests and signaling upgrade carry `X-Cmux-Build-Space`;
/// a build without a build space sends no such header at all, and a misconfigured dev build sends nothing.
@Suite struct LiveAPIBuildSpaceTests {
    static func api(_ buildSpace: CMUXBuildSpace?) throws -> LiveAPI {
        try api(state: buildSpace.map(CMUXBuildSpaceState.dev) ?? .nightly)
    }

    static func api(state buildSpace: CMUXBuildSpaceState) throws -> LiveAPI {
        LiveAPI(baseURL: try #require(URL(string: "https://cmux-mobile-api-dev.debussy.workers.dev")),
                buildSpace: buildSpace) { _ in "token" }
    }

    @Test func aDevBuildsRequestsCarryItsBuildSpace() throws {
        let api = try Self.api(CMUXBuildSpace(devTag: "My_Tag 2"))
        let get = try api.makeRequest("GET", "v1/me/devices")
        #expect(get.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:my-tag-2")
        let post = try api.makeRequest("POST", "v1/teams/t/invites", body: ["email": "a@b.c"])
        #expect(post.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:my-tag-2")
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func aBuildWithoutABuildSpaceSendsNoHeader() throws {
        let request = try Self.api(nil).makeRequest("GET", "v1/me/devices")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Build-Space") == nil)
    }

    @Test func theSignalingUpgradeCarriesTheBuildSpace() async throws {
        let request = try await Self.api(CMUXBuildSpace(devTag: "feat-x")).signalRequest(teamID: "team", deviceID: "phone")
        #expect(request.url?.scheme == "wss")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:feat-x")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let plain = try await Self.api(nil).signalRequest(teamID: "team", deviceID: "phone")
        #expect(plain.value(forHTTPHeaderField: "X-Cmux-Build-Space") == nil)
    }

    @Test func aPinnedTokenKeepsTheBuildSpace() async throws {
        let pinned = try await Self.api(CMUXBuildSpace(devTag: "feat-x")).pinningToken()
        #expect(pinned.buildSpace == CMUXBuildSpaceState(devBuild: true, devTag: "feat-x"))
        #expect(try pinned.makeRequest("DELETE", "v1/devices/d/push").value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:feat-x")
    }

    @Test func aMisconfiguredDevBuildSendsNothing() async throws {
        let api = try Self.api(state: .misconfiguredDev(reason: "it has no tag"))
        #expect(throws: CMUXBuildSpaceError.self) { _ = try api.makeRequest("GET", "v1/me/devices") }
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await api.signalRequest(teamID: "team", deviceID: "phone") }
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await api.call("GET", "v1/me/devices") }
    }
}
