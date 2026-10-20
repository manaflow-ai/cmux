import CmuxInstallAuthCore
import Foundation
@testable import CmuxNextCloud

actor CloudAuthorityWireWorld {
    let socket = CloudAuthorityWireTestSocket()
    let clock = CloudAuthorityWireTestClock()
    private let checked = AsyncStream<Int>.makeStream()
    private let holding = AsyncStream<Void>.makeStream()
    private var hold: CheckedContinuation<Void, Never>?
    private var shouldHold = false
    private var changed = false
    private(set) var checks = 0

    func changeAuthority() { changed = true }
    func holdNextCheck() { shouldHold = true }
    func release() { hold?.resume(); hold = nil }
    func waitUntilHeld() async { var iterator = holding.stream.makeAsyncIterator(); _ = await iterator.next() }
    func nextCheck() async -> Int? { var iterator = checked.stream.makeAsyncIterator(); return await iterator.next() }

    func check() async throws {
        checks += 1
        checked.continuation.yield(checks)
        if shouldHold {
            shouldHold = false
            // Deliberately ignores task cancellation until the test releases the HTTP reply.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                hold = done
                holding.continuation.yield(())
            }
        }
        if changed { throw CloudTeamScope.Failure.changed }
    }

    nonisolated static let now = Date(timeIntervalSince1970: 1_000)
    nonisolated static func lease(owner: CloudAuthorityWireLease.Owner = .team, changes: [String: String] = [:], expiry: Double = 1_300) throws -> CloudAuthorityWireLease {
        var claims: [String: Any] = ["iss": "https://cmux-api/staging", "aud": "api", "sub": "user_1", "inst": "inst_1", "team": "team_1", "grant": "grant_1", "exp": expiry]
        for (key, value) in changes { claims[key] = value }
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URLEncoded
        let context = NativeInstallContext(account: "stack_1", user: "user_1", install: "inst_1", environment: "staging", point: "", token: "", generation: 1, secureStorage: false)
        return try CloudAuthorityWireLease(owner: owner, context: context, team: "team_1", token: "e30.\(payload).sig", now: now)
    }

    nonisolated static func welcome(owner: CloudAuthorityWireLease.Owner = .team, user: String = "user_1") -> String {
        #"{"t":"welcome","principal":{"user":"\#(user)","team":"team_1","install":"inst_1"},"streams":["\#(owner.rawValue):\#(owner == .user ? "user_1" : "team_1")"]}"#
    }
    nonisolated static let snapshot = #"{"t":"snapshot","stream":"team:team_1","seq":0,"state":{},"decided":[]}"#
    nonisolated static let userSnapshot = #"{"t":"snapshot","stream":"user:user_1","seq":0,"state":{},"decided":[]}"#

    func makeWire(owner: CloudAuthorityWireLease.Owner = .team) throws -> CloudAuthorityWire {
        let socket = socket, clock = clock
        return CloudAuthorityWire(lease: try Self.lease(owner: owner), connect: { _ in socket }, recheck: { try await self.check() },
                                  now: { Self.now }, sleep: { try await clock.sleep($0) })
    }

    func exercise(owner: CloudAuthorityWireLease.Owner = .team, _ body: @Sendable (CloudAuthorityWire) async throws -> Void) async throws {
        let wire = try makeWire(owner: owner)
        let running = Task { try await wire.run() }
        do {
            try await body(wire)
            release(); running.cancel(); await clock.finish()
            _ = await running.result
        } catch {
            release(); running.cancel(); await clock.finish()
            _ = await running.result
            throw error
        }
    }
}
