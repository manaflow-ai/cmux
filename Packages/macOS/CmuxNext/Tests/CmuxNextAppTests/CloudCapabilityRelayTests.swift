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
    static let token = "cc1.eyJ2IjoxfQ.c2lnbmF0dXJl"

    /// The API Worker: answers the mint route with a capability for `team_a` (or `mintStatus`), every op with
    /// an empty answer, and records each request's path, bearer and capability header.
    actor Worker: InstallAuthTransport {
        struct Call: Equatable { var path: String; var bearer: String?; var capability: String? }
        var calls: [Call] = []
        var mintStatus = 200
        func refuseMints() { mintStatus = 403 }
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

    static func teamOf(_ token: String) -> String? { token == "install-a" ? "team_a" : token == "install-b" ? "team_b" : nil }

    static func holder(_ worker: Worker, _ install: Install) -> CloudCapabilityHolder {
        CloudCapabilityHolder(transport: worker, headers: ["x-cmux-client-version": "test"], token: { install.token }, teamOf: teamOf)
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
