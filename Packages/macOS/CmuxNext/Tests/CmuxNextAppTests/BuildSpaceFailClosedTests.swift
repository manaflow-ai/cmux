import CMUXAuthCore
import Foundation
@testable import CmuxNextServer
import Testing

/// "Pair Another Machine…"'s invite watch socket is a cloud-api upgrade like any other: a tagged dev build's carries
/// `X-Cmux-Build-Space`, nightly's none, and a misconfigured dev build (no usable tag) opens none and says why.
@Suite struct BuildSpaceFailClosedTests {
    static let base = URL(string: "https://cloud-api-staging.cmux.dev") ?? URL(fileURLWithPath: "/dev/null")
    static let invite = PairInvite(code: "ABCDE12345", expiresAt: Date(timeIntervalSince1970: 1000), watchSecret: "w")
    static let misconfigured = CMUXBuildSpaceState.misconfiguredDev(reason: "it has no tag")

    @Test func theInviteWatchCarriesADevBuildsSpace() throws {
        let request = try PairInviteService.watchRequest(Self.base, invite: Self.invite,
                                                         buildSpace: CMUXBuildSpaceState(devBuild: true, devTag: "My_Tag 2"))
        #expect(request.url?.absoluteString == "wss://cloud-api-staging.cmux.dev/v1/pair/invite/wait?invite=ABCDE12345")
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.pair-invite.v1, watch.w")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Build-Space") == "dev:my-tag-2")
    }

    @Test func nightlysInviteWatchSendsNoHeader() throws {
        let request = try PairInviteService.watchRequest(Self.base, invite: Self.invite, buildSpace: .nightly)
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Build-Space") == nil)
        #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "cmux.pair-invite.v1, watch.w")
    }

    @Test func aMisconfiguredDevBuildOpensNoInviteWatch() async throws {
        #expect(throws: CMUXBuildSpaceError.self) {
            _ = try PairInviteService.watchRequest(Self.base, invite: Self.invite, buildSpace: Self.misconfigured)
        }
        let service = await PairInviteService.cloud(team: { "team_1" }, call: { _, _ in nil },
                                                    texts: .init(failed: { $0 }, unreachable: "unreachable", notMade: "not made"),
                                                    apiBaseURL: Self.base, buildSpace: Self.misconfigured)
        var frames: [PairInviteFrame] = []
        for await frame in service.watch(Self.invite) { frames.append(frame) }
        #expect(frames == [.lost])
    }

    @Test func aMisconfiguredDevBuildsMintSaysWhy() async throws {
        let refusal = CMUXBuildSpaceError.misconfiguredDev(reason: "it has no tag")
        let service = await PairInviteService.cloud(team: { "team_1" }, call: { _, _ in throw refusal },
                                                    texts: .init(failed: { $0 }, unreachable: "unreachable", notMade: "not made"),
                                                    apiBaseURL: Self.base, buildSpace: Self.misconfigured)
        let minted = await service.mint()
        #expect(minted == .failure(.refused(refusal.localizedDescription)))
        #expect(refusal.localizedDescription.contains("no usable build space tag"))
    }
}
