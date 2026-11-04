import Foundation
@testable import CmuxNextCloud
import CmuxNextWakeups
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
        let redial = CloudAppLinkRedial(backoff: Self.fast)
        let (back, cameBack) = AsyncStream.makeStream(of: Void.self)
        #expect(redial.ended(Self.drop) {
            // task-owner: the test's redial; the stream below waits for it
            Task { _ = try? await link.connect(origin: .script); cameBack.yield() }
        })
        for await _ in back { break }
        #expect(await link.currentSocket != nil, "the link did not come back")
        #expect(await resolver.opens == 2)
    }

    @Test func aLinkThatKeepsDroppingStopsAfterItsTries() async {
        let redial = CloudAppLinkRedial(backoff: Self.fast, tries: 3)
        var redials = 0
        func again() { redial.ended(Self.drop) { redials += 1; again() } }
        again()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(redials == 3, "redials: \(redials)")
        #expect(!redial.isPending)
        redial.cancel()
        #expect(redial.ended(Self.drop) {}, "a click starts the count over")
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

    @Test func eachRedialReadsTheRecordFirst() async {
        let redial = CloudAppLinkRedial(backoff: Self.fast)
        var steps: [String] = []
        let (done, finish) = AsyncStream.makeStream(of: Void.self)
        #expect(redial.ended(Self.drop, read: { force in steps.append(force ? "forced read" : "read") }) {
            steps.append("redial")
            finish.yield()
        })
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

    @Test func onlyAHealthyConnectionStartsTheCountOver() async {
        let redial = CloudAppLinkRedial(backoff: Self.fast, tries: 1, healthy: .milliseconds(50))
        #expect(redial.ended(Self.drop) {})
        redial.up()
        #expect(!redial.ended(Self.drop) {}, "a connection that dropped at once spent the try")
        #expect(!redial.ended(Self.drop) {}, "spent until a click or a healthy connection")
        redial.up()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(redial.ended(Self.drop) {}, "a drop after a healthy connection redials again")
    }

    @Test func aCancelStopsThePendingRedial() async {
        let redial = CloudAppLinkRedial(backoff: Self.fast)
        var redials = 0
        #expect(redial.ended(Self.drop) { redials += 1 })
        redial.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(redials == 0 && !redial.isPending)
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
