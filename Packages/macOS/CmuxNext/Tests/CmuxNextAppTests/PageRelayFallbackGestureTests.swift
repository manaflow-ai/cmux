import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextPages
import Foundation
import Testing

/// cmux#37302 review: against a daemon without `origin-claim-v1` page calls go on the main
/// connection, which the daemon takes as the person's own with no page allow list. Before this
/// fix, page script could remove history or import stashes there without a click. Now a call goes
/// through only with the person's own key or pointer event (one call per event) or a sheet.
@MainActor @Suite(.serialized) struct PageRelayFallbackGestureTests {
    /// How a call ended: refused for the missing origin claim, or let through to the main
    /// connection (none in this test, so `notConnected`: the call got past the gesture check).
    private enum Outcome { case refused, forwarded, other }

    /// A History page's channel on a daemon without `origin-claim-v1` and no live connection.
    private static func channel() throws -> PageRelayChannel {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let json = #"{"app":"cmux-tui","protocol":1,"session":"relay-fallback","generation":"g1","capabilities":["v2"]}"#
        services.machines.local.store.noteHandshake(try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8)))
        #expect(!services.machines.local.supports(DaemonClientRole.originClaimCapability))
        #expect(services.machines.local.connection == nil)
        return PageRelayChannel(service: services.machines.local, page: "history")
    }

    private static func outcome(_ channel: PageRelayChannel, _ operation: String, _ context: PageCallContext) async -> Outcome {
        do {
            _ = try await channel.send(operation: operation, params: [:], idempotencyKey: "k", context: context)
            return .other
        } catch DaemonError.missingCapabilities(let missing) where missing == [DaemonClientRole.originClaimCapability] {
            return .refused
        } catch DaemonError.notConnected {
            return .forwarded
        } catch {
            return .other
        }
    }

    @Test func aCallWithoutTheGestureIsRefused() async throws {
        let channel = try Self.channel()
        for operation in ["history.clear", "history.entries.remove", "history.site.remove", "stash.import", "history.entries.list"] {
            #expect(await Self.outcome(channel, operation, PageCallContext(page: "cmux.history")) == .refused)
        }
        // A gesture flag with no event behind it is not the person's.
        #expect(await Self.outcome(channel, "history.clear", PageCallContext(page: "cmux.history", userGesture: true)) == .refused)
    }

    @Test func aCallOnThePersonsGestureIsForwardedOncePerEvent() async throws {
        let channel = try Self.channel()
        let click = PageCallContext(page: "cmux.history", userGesture: true, gestureEvent: 42)
        #expect(await Self.outcome(channel, "history.clear", click) == .forwarded)
        // A second call off the same event is refused; a new event backs a new call, a sheet does too.
        #expect(await Self.outcome(channel, "history.entries.remove", click) == .refused)
        let next = PageCallContext(page: "cmux.history", userGesture: true, gestureEvent: 43)
        #expect(await Self.outcome(channel, "stash.import", next) == .forwarded)
        let sheet = PageCallContext(page: "cmux.history", origin: "user", confirmed: true)
        #expect(await Self.outcome(channel, "history.entries.list", sheet) == .forwarded)
    }
}
