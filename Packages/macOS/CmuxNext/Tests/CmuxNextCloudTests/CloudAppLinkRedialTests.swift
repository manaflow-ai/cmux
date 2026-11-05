import Foundation
@testable import CmuxNextCloud
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A running machine's app link that dropped is dialed again (``CloudAppLinkRedial``, hq#7060): spaced by a
/// capped backoff, bounded by its tries, started over only after a healthy connection, never for a revoke.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudAppLinkRedialTests {
    private static let fast = Backoff(initial: .milliseconds(10), maximum: .milliseconds(40), jitter: 0)
    private static let drop = CloudLinkError.disconnected(reason: "connection ended")

    /// A real ``CloudLinkSession`` whose link drops (`cloud.link.changed` down) comes back through the redial.
    @Test func aDroppedLinkIsDialedAgainAndComesBack() async throws {
        let resolver = CountingResolver()
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm-drop"), resolver: resolver)
        let ticket = try await link.connect(origin: .script)
        _ = try await link.endpoint(ticket)
        let ended = await link.apply(CloudLinkChange(key: link.key, state: .down, generation: nil, reason: "carrier lost"))
        #expect(ended == ticket.id)
        let clock = ManualClock()
        let redial = CloudAppLinkRedial(backoff: Self.fast, clock: clock)
        let (back, cameBack) = AsyncStream.makeStream(of: Void.self)
        #expect(redial.ended(Self.drop) {
            // task-owner: the test's redial; the stream below waits for it
            Task { _ = try? await link.connect(origin: .script); cameBack.yield() }
        })
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(10))
        for await _ in back { break }
        #expect(await link.currentSocket != nil, "the link did not come back")
        #expect(await resolver.opens == 2)
    }

    /// An agent chat's attach dials the carrier again (``CloudLinkSession/streamEndpoint(_:)``): the link
    /// stays up, and only the daemon connection's own second ask is its drop.
    @Test func anotherStreamOnTheCarrierKeepsTheLinkUp() async throws {
        let link = CloudLinkSession(key: CloudLinkKey(machine: "vm-streams"), resolver: CountingResolver())
        let ticket = try await link.connect(origin: .script)
        let first = try await link.endpoint(ticket)
        #expect(try await link.streamEndpoint(ticket) == first)
        #expect(try await link.streamEndpoint(ticket) == first)
        #expect(await link.currentSocket != nil, "a second stream ended the link")
        await #expect(throws: CloudLinkError.self) { try await link.endpoint(ticket) }
        await #expect(throws: CloudLinkError.self) { try await link.streamEndpoint(ticket) }
    }

    @Test func aLinkThatKeepsDroppingStopsAfterItsTries() async throws {
        let clock = ManualClock()
        let redial = CloudAppLinkRedial(backoff: Self.fast, tries: 3, clock: clock)
        let (fired, fire) = AsyncStream.makeStream(of: Void.self)
        var redials = 0
        func again() { redial.ended(Self.drop) { redials += 1; fire.yield(); again() } }
        again()
        var each = fired.makeAsyncIterator()
        // Each redial's connect ends at once: three redials 10, 20 and 40 ms apart, then none.
        for delay in [10, 20, 40] {
            try await clock.waitForSleeper()
            clock.advance(by: .milliseconds(delay))
            _ = await each.next()
        }
        #expect(redials == 3, "redials: \(redials)")
        #expect(clock.sleeperCount == 0, "a fourth redial was scheduled")
        #expect(!redial.isPending)
        redial.cancel()
        #expect(redial.ended(Self.drop) {}, "a click starts the count over")
        redial.cancel()
    }

    @Test func aRevokeOrARefusalAloneIsNeverRedialed() {
        let redial = CloudAppLinkRedial(backoff: Self.fast)
        #expect(!redial.ended(CloudLinkError.revoked(reason: "policy")) {})
        #expect(!redial.ended(CloudLinkError.failed(code: "auth.forbidden", message: "")) {})
        #expect(!redial.isPending)
    }

    @Test func aCarrierNotUpYetRedialsAndOnlyALiveMachineRedials() {
        let redial = CloudAppLinkRedial(backoff: Self.fast)
        #expect(!redial.ended(Self.drop, live: false) {}, "a paused or removed machine's link is never redialed")
        #expect(redial.lastEndRedialable)
        #expect(redial.ended(CloudLinkError.notUp(state: "starting")) {})
        #expect(!redial.ended(CloudLinkError.revoked(reason: "x")) {})
        #expect(!redial.lastEndRedialable, "a start's wait does not redial a revoke either")
    }

    @Test func eachRedialReadsTheRecordFirst() async throws {
        let clock = ManualClock()
        let redial = CloudAppLinkRedial(backoff: Self.fast, clock: clock)
        var steps: [String] = []
        let (done, finish) = AsyncStream.makeStream(of: Void.self)
        #expect(redial.ended(Self.drop, read: { force in steps.append(force ? "forced read" : "read") }) {
            steps.append("redial")
            finish.yield()
        })
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(10))
        for await _ in done { break }
        #expect(steps == ["forced read", "redial"])
    }

    @Test func aMachineNotBoundYetIsRedialableAndOtherRefusalsAreNot() {
        #expect(CloudLinkError.isRedialable(CloudLinkError.failed(code: "cloud.machine.not_bound", message: "still provisioning")))
        #expect(CloudLinkError.isRedialable(CloudLinkError.failed(code: "cmux.cloud.not_bound", message: "")))
        #expect(!CloudLinkError.isRedialable(CloudLinkError.failed(code: "auth.forbidden", message: "")))
        #expect(!CloudLinkError.isRedialable(CloudLinkError.revoked(reason: "x")))
        #expect(!CloudLinkError.isRedialable(CloudLinkError.helperNotRunning(reason: "")))
    }

    @Test func aRedialsFailedConnectGoesOnButARevokeEndsIt() {
        let redial = CloudAppLinkRedial(backoff: Self.fast)
        #expect(redial.ended(Self.drop) {})
        #expect(redial.ended(CloudLinkError.failed(code: "cloud.not_ready", message: "")) {}, "a redial's failed connect goes on")
        #expect(redial.lastEndRedialable, "the session's redial dials it (review F1 at 4eea0da2840b)")
        #expect(!redial.ended(CloudLinkError.revoked(reason: "x")) {})
        #expect(!redial.isPending && redial.ends == 0)
    }

    @Test func onlyAHealthyConnectionStartsTheCountOver() {
        let clock = ManualClock()
        let redial = CloudAppLinkRedial(backoff: Self.fast, tries: 1, healthy: .milliseconds(50), clock: clock)
        #expect(redial.ended(Self.drop) {})
        redial.up()
        #expect(!redial.ended(Self.drop) {}, "a connection that dropped at once spent the try")
        #expect(!redial.ended(Self.drop) {}, "spent until a click or a healthy connection")
        redial.up()
        clock.advance(by: .milliseconds(49))
        #expect(!redial.ended(Self.drop) {}, "up 49 ms is not healthy")
        redial.up()
        clock.advance(by: .milliseconds(50))
        #expect(redial.ended(Self.drop) {}, "a drop after a healthy connection redials again")
        redial.cancel()
    }

    @Test func aCancelStopsThePendingRedial() async throws {
        let clock = ManualClock()
        let redial = CloudAppLinkRedial(backoff: Self.fast, clock: clock)
        var cancelled = 0
        #expect(redial.ended(Self.drop) { cancelled += 1 })
        try await clock.waitForSleeper()
        redial.cancel()
        #expect(!redial.isPending)
        // Far past its deadline: the cancelled redial's sleep ends, and it still never fires.
        clock.advance(by: .seconds(60))
        // A later redial on the same clock fires once its own sleep is due; the cancelled one ran its course before it.
        let (fired, fire) = AsyncStream.makeStream(of: Void.self)
        #expect(redial.ended(Self.drop) { fire.yield() })
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(10))
        for await _ in fired { break }
        #expect(cancelled == 0, "the cancelled redial fired")
    }
}

private actor CountingResolver: CloudLinkResolver {
    var opens = 0
    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        opens += 1
        return CloudLinkSocket(key: key, path: "/tmp/cn-redial-\(opens).sock", generation: 1)
    }

    func close(_ key: CloudLinkKey) async {}
}
