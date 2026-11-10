import CmuxInstallAuthCore
import CmuxNextCloud
@testable import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The signed Cloud capability (cmux-platform#1126): the app mints it at sign-in, on a team switch and on
/// Cloud intent with its install token, holds it in memory, and every op the credential relay posts
/// (`cloud.machine.create`, `.start`, `.list`...) carries it in `x-cmux-cloud-capability` while it is
/// valid for the install token's team. A call never waits for a mint.
@MainActor
@Suite(.serialized)
struct CloudCapabilityRelayTests {
    nonisolated static let token = "cc1.eyJ2IjoxfQ.c2lnbmF0dXJl"

    /// The API Worker: answers the mint route with a capability for `team_a` (or `mintStatus`), every op with
    /// an empty answer, and records each request's path, bearer and capability header.
    actor Worker: InstallAuthTransport {
        struct Call: Equatable { var path: String; var bearer: String?; var capability: String? }
        var calls: [Call] = []
        var mintStatus = 200
        func refuseMints() { mintStatus = 403 }
        func acceptMints() { mintStatus = 200 }
        /// Returns once `count` mints arrived; throws after 10 s (the timer's floor is 1 s a wake).
        func untilMints(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while mints.count < count {
                guard ContinuousClock.now < deadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        var mints: [Call] { calls.filter { $0.path == CloudCapabilityHolder.path } }
        var ops: [Call] { calls.filter { $0.path != CloudCapabilityHolder.path } }

        func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
            calls.append(Call(path: path, bearer: bearer, capability: headers[CloudCapabilityHolder.header]))
            guard path == CloudCapabilityHolder.path else {
                return (200, Data(#"{"ok":true,"value":{"machines":[]},"revision":"1"}"#.utf8))
            }
            guard mintStatus == 200 else { return (mintStatus, Data(#"{"ok":false,"error":{"code":"auth.forbidden","message":"no"}}"#.utf8)) }
            let body = #"{"ok":true,"value":{"capability":"\#(CloudCapabilityRelayTests.token)","team":"team_a","plan_id":"max","cloud":true,"#
                + #""company":false,"limits":null,"issued_at":1000,"expires_at":301000,"refresh_at":241000}}"#
            return (200, Data(body.utf8))
        }

        func get(_ path: String, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) { (404, Data()) }
    }

    /// Which install token the relay sends now (a team switch mints one for the other team).
    final class Install: @unchecked Sendable {
        private let lock = NSLock()
        private var current = "install-a"
        var token: String { lock.withLock { current } }
        func switchTeam() { lock.withLock { current = "install-b" } }
    }

    nonisolated static func teamOf(_ token: String) -> String? { token == "install-a" ? "team_a" : token == "install-b" ? "team_b" : nil }

    /// The seam's own rules, so these cases do not wait for the pinned app FFI to carry Rust's
    /// (cmux-cloud-start-core `capability` has their cases): hold a 200's token, send it to its own team,
    /// mint when none is held for the team.
    nonisolated static let plainRules = CloudCapabilityHolder.Rules(
        mint: { status, body, team, now in
            struct Answer: Decodable { struct Value: Decodable { var capability: String; var team: String }; var value: Value }
            guard status == 200, let answer = try? JSONDecoder().decode(Answer.self, from: body), answer.value.team == team else { return nil }
            return .init(token: answer.value.capability, team: team, expiresAt: now + 300_000, refreshAt: now + 240_000)
        },
        plan: { state, _ in
            guard let team = state.team else { return .init(send: nil, fetch: false, wakeIn: nil) }
            let held = state.held.flatMap { $0.team == team ? $0 : nil }
            return .init(send: held?.token, fetch: held == nil && state.failedTeam != team, wakeIn: nil)
        })

    /// Rust's rules answer through the pinned app FFI (false until the FFI with `cloud_capability_*` is pinned).
    nonisolated static var rustRulesPinned: Bool {
        CloudCapabilityHolder.Rules.rust.plan(.init(held: nil, team: "team_a", now: 0), .intent) != nil
    }

    static func holder(_ worker: Worker, _ install: Install, rules: CloudCapabilityHolder.Rules = plainRules) -> CloudCapabilityHolder {
        CloudCapabilityHolder(transport: worker, headers: ["x-cmux-client-version": "test"], token: { install.token }, teamOf: teamOf, rules: rules)
    }

    /// The relay with the post ``CloudCredentialRelay/live`` builds, serving the start path's ops.
    static func relay(_ worker: Worker, _ install: Install, _ capability: CloudCapabilityHolder?) -> CloudCredentialRelay {
        CloudCredentialRelay(
            post: CloudCapabilityHolder.relayPost(transport: worker, headers: [:], capability: capability),
            token: { install.token },
            invalidate: {},
            session: { CloudCredentialRelay.Session(signedIn: true, team: teamOf(install.token)) },
            allowedOps: { ["cloud.machine.create", "cloud.machine.start", "cloud.machine.list"] })
    }

    static func send(_ op: String, key: String?, relay: CloudCredentialRelay) async throws {
        let result = try await CloudCredentialRelayRefusalTests.answer(try CloudCredentialRelayRefusalTests.line(id: 3, op: op, key: key), relay: relay)
        #expect(result.ok == true, "\(op)")
    }

    @Test func signInMintsOnceAndEveryStartCreateAndReadCarriesIt() async throws {
        let worker = Worker(), install = Install()
        let capability = Self.holder(worker, install)
        await capability.intent()
        let relay = Self.relay(worker, install, capability)
        try await Self.send("cloud.machine.create", key: "k-create", relay: relay)
        try await Self.send("cloud.machine.start", key: "k-start", relay: relay)
        try await Self.send("cloud.machine.list", key: nil, relay: relay)

        let mints = await worker.mints
        #expect(mints == [.init(path: CloudCapabilityHolder.path, bearer: "install-a", capability: nil)], "minted once, with the install token")
        let ops = await worker.ops
        #expect(ops.map(\.path) == ["v1/ops", "v1/ops", "v1/read"])
        #expect(ops.allSatisfy { $0.capability == Self.token && $0.bearer == "install-a" })
    }

    @Test func aCallBeforeAnyMintGoesWithoutOneAndStartsTheMint() async throws {
        let worker = Worker(), install = Install()
        let capability = Self.holder(worker, install)
        let relay = Self.relay(worker, install, capability)
        try await Self.send("cloud.machine.create", key: "k-1", relay: relay)
        #expect(await worker.ops.first?.capability == nil, "today's full checks; the call never waits")
        await capability.intent() // joins the mint the call started
        try await Self.send("cloud.machine.create", key: "k-2", relay: relay)
        #expect(await worker.ops.last?.capability == Self.token)
        #expect(await worker.mints.count == 1)
    }

    @Test func afterATeamSwitchTheOldTeamsCapabilityIsNeverSent() async throws {
        let worker = Worker(), install = Install()
        let capability = Self.holder(worker, install)
        await capability.intent()
        install.switchTeam()
        try await Self.send("cloud.machine.create", key: "k-1", relay: Self.relay(worker, install, capability))
        let create = await worker.ops.last
        #expect(create?.bearer == "install-b")
        #expect(create?.capability == nil)
    }

    @Test func aRefusedMintSendsNothingAndTheCallStillGoes() async throws {
        let worker = Worker(), install = Install()
        await worker.refuseMints()
        let capability = Self.holder(worker, install)
        await capability.intent()
        #expect(await capability.holds == false)
        try await Self.send("cloud.machine.create", key: "k-1", relay: Self.relay(worker, install, capability))
        #expect(await worker.ops.last?.capability == nil)
    }

    /// The same flow on Rust's rules, through the app FFI.
    @Test(.enabled(if: rustRulesPinned)) func rustsRulesSendTheMintedCapabilityOnACreate() async throws {
        let worker = Worker(), install = Install()
        let capability = Self.holder(worker, install, rules: .rust)
        await capability.intent()
        #expect(await capability.holds)
        try await Self.send("cloud.machine.create", key: "k-1", relay: Self.relay(worker, install, capability))
        #expect(await worker.ops.last?.capability == Self.token)
        install.switchTeam()
        try await Self.send("cloud.machine.create", key: "k-2", relay: Self.relay(worker, install, capability))
        #expect(await worker.ops.last?.capability == nil)
    }

    /// The install token a test hands out only when it says so, so a clear can land while intent() waits on it.
    actor Gate {
        private var asked: CheckedContinuation<Void, Never>?
        private var waiting: CheckedContinuation<String, Never>?
        func token() async -> String {
            await withCheckedContinuation { waiting = $0; asked?.resume(); asked = nil }
        }
        func untilAsked() async { if waiting == nil { await withCheckedContinuation { asked = $0 } } }
        func release(_ token: String) { waiting?.resume(returning: token); waiting = nil }
    }

    /// cmux#40172 F1: a sign-out while intent() waits for the install token keeps nothing that mint answers.
    @Test func aSignOutWhileIntentWaitsForTheTokenKeepsNothing() async throws {
        let worker = Worker(), gate = Gate()
        let capability = CloudCapabilityHolder(transport: worker, headers: [:], token: { await gate.token() },
                                               teamOf: Self.teamOf, rules: Self.plainRules)
        let intent = Task { await capability.intent() }
        await gate.untilAsked()
        await capability.clear()
        await gate.release("install-a")
        await intent.value
        #expect(await capability.holds == false, "the signed-out account's capability came back")
        #expect(await worker.mints.isEmpty, "no mint for the signed-out account")
    }

    /// cmux#40172 F2: a refresh that fails re-arms the timer, and the next one holds a capability again.
    @Test func aFailedRefreshIsRetriedAndRecovers() async throws {
        let worker = Worker(), install = Install()
        // Due at once, so the timer refreshes as soon as it may (Rust's rules hold the real times and backoff).
        let rules = CloudCapabilityHolder.Rules(mint: Self.plainRules.mint, plan: { state, _ in
            let held = state.held.flatMap { $0.team == state.team ? $0 : nil }
            return .init(send: held?.token, fetch: state.team != nil, wakeIn: held == nil ? nil : 0)
        })
        let capability = Self.holder(worker, install, rules: rules)
        await capability.intent()
        await worker.refuseMints()
        try await worker.untilMints(2) // the timer's refresh, refused
        await worker.acceptMints()
        try await worker.untilMints(3) // the retry, answered
        #expect(await capability.holds)
        await capability.clear()
    }

    /// Due at once, so the timer refreshes as soon as it may (Rust's rules hold the real times and backoff).
    nonisolated static let dueRules = CloudCapabilityHolder.Rules(mint: plainRules.mint, plan: { state, _ in
        let held = state.held.flatMap { $0.team == state.team ? $0 : nil }
        return .init(send: held?.token, fetch: state.team != nil, wakeIn: held == nil ? nil : 0)
    })

    /// An install token that fails while `failing` is set, counting each failure.
    final class FlakyToken: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false, failures = 0
        func set(failing: Bool) { lock.withLock { self.failing = failing } }
        var failed: Int { lock.withLock { failures } }
        func token() throws -> String {
            try lock.withLock {
                guard !failing else { failures += 1; throw URLError(.notConnectedToInternet) }
                return "install-a"
            }
        }
    }

    /// Follow-up F1 on cmux#40172: a refresh whose install token fails once retries by itself and recovers.
    @Test func aRefreshWhoseTokenFailsRetriesAndRecovers() async throws {
        let worker = Worker(), flaky = FlakyToken()
        let capability = CloudCapabilityHolder(transport: worker, headers: [:], token: { try flaky.token() },
                                               teamOf: Self.teamOf, rules: Self.dueRules)
        await capability.intent()
        #expect(await worker.mints.count == 1)
        flaky.set(failing: true)
        let deadline = ContinuousClock.now + .seconds(10)
        while flaky.failed == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(flaky.failed > 0, "the timer's refresh asked for a token")
        flaky.set(failing: false)
        try await worker.untilMints(2) // no call or intent: the timer alone
        #expect(await capability.holds)
        await capability.clear()
    }

    /// Follow-up F2 on cmux#40172: an intent for team B while team A's mint is in flight gets team B's capability.
    @Test func anIntentForAnotherTeamDuringAMintGetsThatTeamsCapability() async throws {
        actor Mints {
            var asked: [String] = []
            private var releaseA: CheckedContinuation<Void, Never>?
            func mint(_ bearer: String) async -> (status: Int, body: Data) {
                asked.append(bearer)
                if bearer == "install-a" { await withCheckedContinuation { releaseA = $0 } }
                let team = CloudCapabilityRelayTests.teamOf(bearer) ?? ""
                return (200, Data(#"{"ok":true,"value":{"capability":"cc1.\#(team).sig","team":"\#(team)"}}"#.utf8))
            }
            func release() { releaseA?.resume(); releaseA = nil }
        }
        let mints = Mints(), install = Install()
        let capability = CloudCapabilityHolder(mint: { await mints.mint($0) }, token: { install.token },
                                               teamOf: Self.teamOf, rules: Self.plainRules)
        let first = Task { await capability.intent() }
        var deadline = ContinuousClock.now + .seconds(10)
        while await mints.asked.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        install.switchTeam()
        let second = Task { await capability.intent() }
        deadline = ContinuousClock.now + .seconds(2)
        while await !mints.asked.contains("install-b"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await mints.release() // team A's answer lands late
        await first.value
        await second.value
        #expect(await mints.asked.contains("install-b"), "team B was never minted")
        #expect(await capability.header(forBearer: "install-b") == "cc1.team_b.sig")
        await capability.clear()
    }

    /// Review F1 on cmux#40384: A, then B, then A again. The first A mint's late cancellation, delivered while
    /// the second A mint runs, must not drop the second A's capability.
    @Test func aLateCancellationOfASupersededMintKeepsTheReplacementsCapability() async throws {
        actor Mints {
            var asked: [String] = []
            private var gates: [Int: CheckedContinuation<Bool, Never>] = [:]
            func mint(_ bearer: String) async throws -> (status: Int, body: Data) {
                let index = asked.count
                asked.append(bearer)
                if index < 3, await withCheckedContinuation({ gates[index] = $0 }) == false { throw CancellationError() }
                let team = CloudCapabilityRelayTests.teamOf(bearer) ?? ""
                return (200, Data(#"{"ok":true,"value":{"capability":"cc1.\#(team).sig","team":"\#(team)"}}"#.utf8))
            }
            /// Answers mint `index`: its capability, or a cancellation.
            func answer(_ index: Int, ok: Bool) { gates.removeValue(forKey: index)?.resume(returning: ok) }
            func until(_ count: Int) async throws {
                let deadline = ContinuousClock.now + .seconds(10)
                while asked.count < count || gates.count < min(count, 3) {
                    guard ContinuousClock.now < deadline else { throw CancellationError() }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        final class Current: @unchecked Sendable {
            private let lock = NSLock()
            private var token = "install-a"
            var value: String { lock.withLock { token } }
            func set(_ token: String) { lock.withLock { self.token = token } }
        }
        let mints = Mints(), current = Current()
        let capability = CloudCapabilityHolder(mint: { try await mints.mint($0) }, token: { current.value },
                                               teamOf: Self.teamOf, rules: Self.plainRules)
        let firstA = Task { await capability.intent() }
        try await mints.until(1)
        current.set("install-b")
        let teamB = Task { await capability.intent() }
        try await mints.until(2)
        current.set("install-a")
        let secondA = Task { await capability.intent() }
        try await mints.until(3)
        #expect(await mints.asked == ["install-a", "install-b", "install-a"])
        await mints.answer(0, ok: false) // the first A's cancellation lands after the second A started
        await mints.answer(2, ok: true)
        await mints.answer(1, ok: true) // B's late answer
        await firstA.value
        await teamB.value
        await secondA.value
        #expect(await capability.holds, "the second A's capability was dropped")
        #expect(await capability.header(forBearer: "install-a") == "cc1.team_a.sig")
        await capability.clear()
    }

    @Test func signOutForgetsIt() async throws {
        let worker = Worker(), install = Install()
        let capability = Self.holder(worker, install)
        await capability.intent()
        #expect(await capability.holds)
        await capability.clear()
        #expect(await capability.holds == false)
        try await Self.send("cloud.machine.list", key: nil, relay: Self.relay(worker, install, nil))
        #expect(await worker.ops.last?.capability == nil)
    }
}
