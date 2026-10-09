import CmuxNextApps
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The provider channel over a recorded link: registration per connection,
/// a retry after a taken family, cancellation on a new connection, and the
/// organization policy.
@MainActor
@Suite struct AppsProviderChannelTests {
    /// A link that records every registration and answer; registrations
    /// answer with the next queued refusal (nil: accepted).
    final class RecordedLink {
        var registrations: [[String]] = []
        var refusals: [String?] = []
        var answers: [(id: UInt64, ok: Bool, body: AppJSON)] = []
        var link: AppsProviderLink {
            AppsProviderLink(register: { [self] families in
                registrations.append(families)
                return refusals.isEmpty ? nil : refusals.removeFirst()
            }, answer: { [self] id, ok, body in answers.append((id, ok, body)) })
        }
    }

    /// Answers `slow.*` only after `release()`; `echo.*` at once.
    nonisolated final class GatedOps: AppHostCapabilityHandler, Sendable {
        private let gate = AsyncStream<Void>.makeStream()
        var families: Set<String> { ["echo", "slow"] }

        func release() { gate.continuation.yield() }

        func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
            if request.op.hasPrefix("slow.") {
                for await _ in gate.stream { break }
            }
            return ["op": .string(request.op)]
        }
    }

    private func request(_ id: Int, _ op: String) -> CmuxNextDaemon.JSONValue {
        .object(["event": .string("apps-provider-request"), "request_id": .number(Double(id)), "app": .string("cmux/coderouter"),
                 "op": .string(op), "params": .object([:]), "origin": .string("user")])
    }

    @Test func registersOncePerConnectionAndAnswersACall() async {
        let recorded = RecordedLink()
        let channel = AppsProviderChannel(link: recorded.link)
        channel.attach(AppHostCapabilities([GatedOps()]))
        channel.connectionChanged(epoch: 1)
        channel.connectionChanged(epoch: 1)
        #expect(await eventually { channel.isRegistered })
        #expect(recorded.registrations == [["echo", "slow"]])
        #expect(channel.handle(name: "apps-provider-request", payload: request(1, "echo.ping")))
        #expect(await eventually { recorded.answers.count == 1 })
        #expect(recorded.answers.first?.ok == true && recorded.answers.first?.body == ["op": "echo.ping"])
    }

    /// A family another live connection still holds: the next supervisor
    /// event tries the registration again; another refusal waits for the next
    /// connection.
    @Test func aTakenFamilyIsRegisteredAgainOnTheNextEvent() async {
        let recorded = RecordedLink()
        recorded.refusals = ["apps.provider.taken"]
        let channel = AppsProviderChannel(link: recorded.link)
        channel.attach(AppHostCapabilities([GatedOps()]))
        channel.connectionChanged(epoch: 1)
        #expect(await eventually { recorded.registrations.count == 1 })
        #expect(!channel.isRegistered)
        _ = channel.handle(name: "apps-changed", payload: .object(["event": .string("apps-changed")]))
        #expect(await eventually { channel.isRegistered })
        #expect(recorded.registrations.count == 2)

        let forbidden = RecordedLink()
        forbidden.refusals = ["apps.provider.forbidden"]
        let other = AppsProviderChannel(link: forbidden.link)
        other.attach(AppHostCapabilities([GatedOps()]))
        other.connectionChanged(epoch: 1)
        #expect(await eventually { forbidden.registrations.count == 1 })
        _ = other.handle(name: "apps-changed", payload: .object(["event": .string("apps-changed")]))
        other.connectionChanged(epoch: 1)
        #expect(forbidden.registrations.count == 1, "only a taken family is retried on the same connection")
        other.connectionChanged(epoch: 2)
        #expect(await eventually { other.isRegistered })
    }

    /// A reconnect (epoch N to N+1, also inside one frame) cancels the old
    /// connection's calls: their results never go out.
    @Test func aNewConnectionCancelsTheOldConnectionsCalls() async {
        let recorded = RecordedLink()
        let ops = GatedOps()
        let channel = AppsProviderChannel(link: recorded.link)
        channel.attach(AppHostCapabilities([ops]))
        channel.connectionChanged(epoch: 1)
        _ = channel.handle(name: "apps-provider-request", payload: request(7, "slow.wait"))
        #expect(channel.runningCount == 1)
        channel.connectionChanged(epoch: 2)
        #expect(channel.runningCount == 0)
        ops.release()
        _ = channel.handle(name: "apps-provider-request", payload: request(8, "echo.ping"))
        #expect(await eventually { recorded.answers.contains { $0.id == 8 } })
        #expect(!recorded.answers.contains { $0.id == 7 })
    }

    /// While an administrator turned apps off, no handler runs: every call
    /// answers `apps.disabled`, and running calls are cancelled.
    @Test func turnedOffAnswersEveryCallDisabled() async {
        let recorded = RecordedLink()
        let ops = GatedOps()
        let channel = AppsProviderChannel(link: recorded.link)
        channel.attach(AppHostCapabilities([ops]))
        channel.connectionChanged(epoch: 1)
        _ = channel.handle(name: "apps-provider-request", payload: request(1, "slow.wait"))
        channel.turnedOff = "Turned off by your organization"
        #expect(channel.runningCount == 0)
        _ = channel.handle(name: "apps-provider-request", payload: request(2, "echo.ping"))
        #expect(await eventually { recorded.answers.contains { $0.id == 2 } })
        let answer = recorded.answers.first { $0.id == 2 }
        #expect(answer?.ok == false && answer?.body["code"] == "apps.disabled")
        #expect(answer?.body["message"] == "Turned off by your organization")
        ops.release()
        #expect(!recorded.answers.contains { $0.id == 1 })
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
