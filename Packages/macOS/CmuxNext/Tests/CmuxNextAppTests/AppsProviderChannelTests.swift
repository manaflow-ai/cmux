import CmuxNextApps
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The provider channel over a recorded link: one registration per
/// connection, retried with backoff; answers on the connection a request
/// arrived on; cancellation on a new connection; the organization policy.
@MainActor
@Suite struct AppsProviderChannelTests {
    /// One daemon connection of the recorded link.
    final class Connection {
        let name: String
        init(_ name: String) { self.name = name }
    }

    /// A link that records every registration and answer, by connection;
    /// registrations answer with the next queued refusal (nil: accepted).
    final class RecordedLink {
        var current: Connection? = Connection("A")
        var registrations: [(connection: String, families: [String])] = []
        var refusals: [String?] = []
        var answers: [(connection: String, id: UInt64, ok: Bool, body: AppJSON)] = []
        var link: AppsProviderLink {
            AppsProviderLink(connection: { [self] in current }, register: { [self] connection, families in
                registrations.append(((connection as? Connection)?.name ?? "?", families))
                return refusals.isEmpty ? nil : refusals.removeFirst()
            }, answer: { [self] connection, id, ok, body in
                answers.append(((connection as? Connection)?.name ?? "?", id, ok, body))
            })
        }
    }

    /// Answers `slow.*` only after `release()` and counts the slow calls that
    /// returned; `echo.*` at once.
    nonisolated final class GatedOps: AppHostCapabilityHandler, Sendable {
        private let gate = AsyncStream<Void>.makeStream()
        private let done = AsyncStream<Void>.makeStream()
        var families: Set<String> { ["echo", "slow"] }

        func release() { gate.continuation.yield() }

        /// Waits until one slow call returned from its handler.
        func waitForSlowReturn() async {
            for await _ in done.stream { return }
        }

        func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
            if request.op.hasPrefix("slow.") {
                for await _ in gate.stream { break }
                done.continuation.yield()
            }
            return ["op": .string(request.op)]
        }
    }

    private func request(_ id: Int, _ op: String) -> CmuxNextDaemon.JSONValue {
        .object(["event": .string("apps-provider-request"), "request_id": .number(Double(id)), "app": .string("cmux/coderouter"),
                 "op": .string(op), "params": .object([:]), "origin": .string("user")])
    }

    private func channel(_ recorded: RecordedLink, _ ops: GatedOps = GatedOps()) -> AppsProviderChannel {
        let channel = AppsProviderChannel(link: recorded.link, backoff: { _ in .zero })
        channel.attach(AppHostCapabilities([ops]))
        return channel
    }

    @Test func registersOncePerConnectionAndAnswersACall() async {
        let recorded = RecordedLink()
        let channel = channel(recorded)
        channel.connectionChanged(epoch: 1)
        channel.connectionChanged(epoch: 1)
        #expect(await eventually { channel.isRegistered })
        #expect(recorded.registrations.map(\.families) == [["echo", "slow"]])
        #expect(channel.handle(name: "apps-provider-request", payload: request(1, "echo.ping")))
        #expect(await eventually { recorded.answers.count == 1 })
        #expect(recorded.answers.first?.ok == true && recorded.answers.first?.body == ["op": "echo.ping"])
    }

    /// A result goes to the connection its request arrived on, never to a newer one.
    @Test func aResultGoesToTheConnectionTheRequestArrivedOn() async {
        let recorded = RecordedLink()
        let ops = GatedOps()
        let channel = channel(recorded, ops)
        channel.connectionChanged(epoch: 1)
        _ = channel.handle(name: "apps-provider-request", payload: request(3, "slow.wait"))
        recorded.current = Connection("B")
        ops.release()
        await ops.waitForSlowReturn()
        #expect(await eventually { recorded.answers.contains { $0.id == 3 } })
        #expect(recorded.answers.filter { $0.id == 3 }.map(\.connection) == ["A"])
    }

    /// Taken families and transient failures are retried on the same
    /// connection with backoff, one registration at a time; supervisor events
    /// never start one. A refusal for good waits for the next connection.
    @Test func aRefusedRegistrationIsRetriedWithBackoff() async {
        let recorded = RecordedLink()
        recorded.refusals = ["apps.provider.taken", "failed", "not_connected", "timeout"]
        let channel = channel(recorded)
        channel.connectionChanged(epoch: 1)
        #expect(await eventually { channel.isRegistered })
        #expect(recorded.registrations.count == 5)

        let forbidden = RecordedLink()
        forbidden.refusals = ["apps.provider.forbidden"]
        let other = self.channel(forbidden)
        other.connectionChanged(epoch: 1)
        #expect(await eventually { forbidden.registrations.count == 1 })
        for _ in 0..<5 { _ = other.handle(name: "apps-changed", payload: .object(["event": .string("apps-changed")])) }
        other.connectionChanged(epoch: 1)
        await Task.yield()
        #expect(forbidden.registrations.count == 1, "no registration per event, none after a refusal for good")
        other.connectionChanged(epoch: 2)
        #expect(await eventually { other.isRegistered })
    }

    @Test func theBackoffDoublesUpToItsCap() {
        #expect(AppsProviderChannel.backoff(0) == .milliseconds(500))
        #expect(AppsProviderChannel.backoff(1) == .seconds(1))
        #expect(AppsProviderChannel.backoff(3) == .seconds(4))
        #expect(AppsProviderChannel.backoff(20) == .seconds(30))
    }

    /// A reconnect (epoch N to N+1, also inside one frame) cancels the old
    /// connection's calls: their results never go out.
    @Test func aNewConnectionCancelsTheOldConnectionsCalls() async {
        let recorded = RecordedLink()
        let ops = GatedOps()
        let channel = channel(recorded, ops)
        channel.connectionChanged(epoch: 1)
        _ = channel.handle(name: "apps-provider-request", payload: request(7, "slow.wait"))
        #expect(channel.runningCount == 1)
        recorded.current = Connection("B")
        channel.connectionChanged(epoch: 2)
        #expect(channel.runningCount == 0)
        ops.release()
        await ops.waitForSlowReturn()
        _ = channel.handle(name: "apps-provider-request", payload: request(8, "echo.ping"))
        #expect(await eventually { recorded.answers.contains { $0.id == 8 } })
        #expect(!recorded.answers.contains { $0.id == 7 })
    }

    /// While an administrator turned apps off, no handler runs: every call,
    /// the running ones included, answers `apps.disabled` once.
    @Test func turnedOffAnswersEveryCallDisabled() async {
        let recorded = RecordedLink()
        let ops = GatedOps()
        let channel = channel(recorded, ops)
        channel.connectionChanged(epoch: 1)
        _ = channel.handle(name: "apps-provider-request", payload: request(1, "slow.wait"))
        channel.turnedOff = "Turned off by your organization"
        #expect(channel.runningCount == 0)
        _ = channel.handle(name: "apps-provider-request", payload: request(2, "echo.ping"))
        #expect(await eventually { recorded.answers.contains { $0.id == 1 } && recorded.answers.contains { $0.id == 2 } })
        for id: UInt64 in [1, 2] {
            let answer = recorded.answers.first { $0.id == id }
            #expect(answer?.ok == false && answer?.body["code"] == "apps.disabled", "\(id)")
            #expect(answer?.body["message"] == "Turned off by your organization")
        }
        ops.release()
        await ops.waitForSlowReturn()
        await Task.yield()
        #expect(recorded.answers.filter { $0.id == 1 }.count == 1, "the cancelled call sends no second answer")
    }
}

/// The transport's pure rules: availability from the connection and the
/// capability, and the `apps-run` origin.
@Suite struct DaemonAppsTransportRulesTests {
    @Test func availabilityFollowsTheConnectionAndTheCapability() {
        #expect(DaemonAppsTransport.unavailableReason(capabilities: nil) == .notConnected)
        #expect(DaemonAppsTransport.unavailableReason(capabilities: ["bookmarks-v1"]) == .needsNewerDaemon)
        #expect(DaemonAppsTransport.unavailableReason(capabilities: ["apps-v1", "bookmarks-v1"]) == nil)
    }

    /// `user` only for a user origin on a verified connection; a CLI, MCP or
    /// script run, or an unverified connection, sends `script`.
    @Test func aRunIsUserOnlyForAUserOnAVerifiedConnection() {
        #expect(DaemonAppsTransport.wireOrigin(.user, userOriginAllowed: true) == .user)
        #expect(DaemonAppsTransport.wireOrigin(.user, userOriginAllowed: false) == .script)
        for origin in [AppOrigin.cli, .mcp, .script, .remote] {
            #expect(DaemonAppsTransport.wireOrigin(origin, userOriginAllowed: true) == .script, "\(origin)")
        }
    }

    /// The palette reaches presented apps only; the CLI, MCP and automations
    /// also reach a hidden app whose `hidden_access` allows that channel.
    @Test func hiddenAppsAreReachedPerChannel() throws {
        let manifest = try #require(AppManifest(json: ["id": "cmux/x", "name": "X", "version": "1.0.0"]))
        var app = AppRecord(manifest: manifest, tier: .firstParty, installed: true, source: .user)
        app.hidden = true
        app.hiddenAccess = AppRecord.HiddenAccess(cli: true, mcp: false, automations: true)
        #expect(!AppCommandPalette.reaches(app, origin: .user, presented: false))
        #expect(AppCommandPalette.reaches(app, origin: .cli, presented: false))
        #expect(!AppCommandPalette.reaches(app, origin: .mcp, presented: false))
        #expect(AppCommandPalette.reaches(app, origin: .script, presented: false))
        app.enabled = false
        #expect(!AppCommandPalette.reaches(app, origin: .cli, presented: false), "a disabled app runs nothing")
    }
}
