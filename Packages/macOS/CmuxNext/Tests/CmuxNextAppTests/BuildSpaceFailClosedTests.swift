import CMUXAuthCore
import Foundation
import CmuxNextCloud
@testable import CmuxNextServer
import Testing

/// "Pair Another Machine…"'s invite watch socket is a cloud-api upgrade like any other, opened by the bundled `cmux`
/// (`cmux cloud pair-invite-watch`, its URL and headers tested in cmux-tui): a tagged dev build's child gets its
/// `CMUX_BUILD_SPACE`, nightly's none, and a misconfigured dev build (no usable tag) runs none and says why.
@Suite struct BuildSpaceFailClosedTests {
    static let base = URL(string: "https://cloud-api-staging.cmux.dev") ?? URL(fileURLWithPath: "/dev/null")
    static let invite = PairInvite(code: "ABCDE12345", expiresAt: Date(timeIntervalSince1970: 1000), watchSecret: "w")
    static let misconfigured = CMUXBuildSpaceState.misconfiguredDev(reason: "it has no tag")
    static let texts = PairInviteService.CloudTexts(failed: { $0 }, unreachable: "unreachable", notMade: "not made")

    /// What the fake `cmux` was run with, and the lines it prints.
    final class Child: @unchecked Sendable {
        let lock = NSLock()
        var runs: [(arguments: [String], stdin: Data, environment: [String: String]?)] = []
        let output: [String]
        init(output: [String]) { self.output = output }
        var lines: CloudCLICall.Lines {
            { [self] arguments, stdin, environment, line in
                lock.withLock { runs.append((arguments, stdin, environment)) }
                for text in output { line(Data(text.utf8)) }
            }
        }
    }

    @Test func theInviteWatchCarriesADevBuildsSpace() throws {
        let environment = try PairInviteService.watchEnvironment(CMUXBuildSpaceState(devBuild: true, devTag: "My_Tag 2"))
        #expect(environment["CMUX_BUILD_SPACE"] == CMUXBuildSpaceState(devBuild: true, devTag: "My_Tag 2").childEnvironmentValue)
        #expect(environment["CMUX_BUILD_SPACE"] != nil)
    }

    @Test func nightlysInviteWatchSendsNoSpace() throws {
        #expect(try PairInviteService.watchEnvironment(.nightly)["CMUX_BUILD_SPACE"] == nil)
    }

    @Test func aMisconfiguredDevBuildOpensNoInviteWatch() async throws {
        #expect(throws: CMUXBuildSpaceError.self) { _ = try PairInviteService.watchEnvironment(Self.misconfigured) }
        let child = Child(output: [#"{"t":"arrived","code":"XYZ"}"#])
        let service = await PairInviteService.cloud(team: { "team_1" }, call: { _, _ in nil }, texts: Self.texts,
                                                    apiBaseURL: Self.base, buildSpace: Self.misconfigured, lines: child.lines)
        var frames: [PairInviteFrame] = []
        for await frame in service.watch(Self.invite) { frames.append(frame) }
        #expect(frames == [.lost])
        #expect(child.lock.withLock { child.runs.isEmpty })
    }

    @Test func theWatchChildsLinesAreTheCardsFrames() async throws {
        let child = Child(output: [#"{"t":"arrived","code":"XYZ"}"#, "not json", #"{"closed":4408}"#])
        let service = await PairInviteService.cloud(team: { "team_1" }, call: { _, _ in nil }, texts: Self.texts,
                                                    apiBaseURL: Self.base, buildSpace: .nightly, lines: child.lines)
        var frames: [PairInviteFrame] = []
        for await frame in service.watch(Self.invite) { frames.append(frame) }
        #expect(frames.count == 2)
        #expect(frames.last == .expired)
        let run = try #require(child.lock.withLock { child.runs.first })
        #expect(run.arguments == ["cloud", "pair-invite-watch"])
        let stdin = try #require(try JSONSerialization.jsonObject(with: run.stdin) as? [String: String])
        #expect(stdin == ["api": "https://cloud-api-staging.cmux.dev", "invite": "ABCDE12345", "secret": "w"])
        #expect(run.environment?["CMUX_BUILD_SPACE"] == nil)
    }

    @Test func aChildThatEndsWithNoCloseLineIsLost() async throws {
        let child = Child(output: [])
        let service = await PairInviteService.cloud(team: { "team_1" }, call: { _, _ in nil }, texts: Self.texts,
                                                    apiBaseURL: Self.base, buildSpace: .nightly, lines: child.lines)
        var frames: [PairInviteFrame] = []
        for await frame in service.watch(Self.invite) { frames.append(frame) }
        #expect(frames == [.lost])
    }

    @Test func aMisconfiguredDevBuildsMintSaysWhy() async throws {
        let refusal = CMUXBuildSpaceError.misconfiguredDev(reason: "it has no tag")
        let service = await PairInviteService.cloud(team: { "team_1" }, call: { _, _ in throw refusal }, texts: Self.texts,
                                                    apiBaseURL: Self.base, buildSpace: Self.misconfigured, lines: Child(output: []).lines)
        let minted = await service.mint()
        #expect(minted == .failure(.refused(refusal.localizedDescription)))
        #expect(refusal.localizedDescription.contains("no usable build space tag"))
    }
}
