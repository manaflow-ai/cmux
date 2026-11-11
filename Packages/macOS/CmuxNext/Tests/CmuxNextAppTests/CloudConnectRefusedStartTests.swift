import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A Cloud start whose connect can never succeed ends at once with the reason and a Retry (a tagged DEV
/// build, 2026-11-10: every `carrier serve` refused to start because the Keychain refused its device key,
/// and the composer's start showed "Thinking" while the link was connected again and again until the
/// start's 180 s wait gave up with a bare "didn't connect"). Its link is dialed once, not again.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudConnectRefusedStartTests {
    /// The app link's connect: `carrier serve` refusing to start for want of its device key, every time, with
    /// the line Rust writes for it (`start_refusal_line`: `"final":true`), read as the resolver reads it.
    private actor RefusingResolver: CloudLinkResolver {
        static let line = #"{"ok":false,"error_code":"handshake","error_detail":"the Keychain refused the carrier key (-128)","final":true,"route":"carrier"}"#
        private(set) var opens = 0
        /// One element per open, so a test knows a connect reached the link.
        nonisolated let openings: AsyncStream<Void>
        private let opened: AsyncStream<Void>.Continuation

        init() {
            let (openings, opened) = AsyncStream.makeStream(of: Void.self)
            self.openings = openings
            self.opened = opened
        }

        func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
            opens += 1
            opened.yield()
            guard case .refused(let code, let detail, let isFinal)? = CloudCarrierDial.serveLine(Self.line) else { throw CloudLinkError.unsupported }
            throw CloudCarrierDial.serveStartError(code: code, detail: detail, isFinal: isFinal, socket: "/tmp/cmux-link-0123456789ab.sock")
        }

        func close(_ key: CloudLinkKey) async {}
    }

    private static func session(_ resolver: RefusingResolver) -> CloudMachineSession {
        let id = "vm-refused-\(UUID().uuidString.prefix(8))"
        return CloudMachineSession(machine: CloudMachine(id: id, status: .running, displayName: "Refused VM"),
                                   appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                   localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    /// The PR's before/after harness: a start's wait (``CloudMachineSession/linkUp(within:clock:)``, the start's
    /// 180 s) on a virtual clock, from the serve's first refusal to the wait's end, and how often the wait started
    /// serve again. Each redial's connect reaches its refusal before the clock moves on, as a real one does in
    /// milliseconds against the redial's seconds. Prints one `bench refused-start` line.
    @Test func benchARefusedStartsWaitOnAVirtualClock() async throws {
        @MainActor final class Ended { var up: Bool? }
        let resolver = RefusingResolver()
        let session = Self.session(resolver)
        defer { session.disconnect() }
        let clock = ManualClock(), ended = Ended()
        var openings = resolver.openings.makeAsyncIterator(), seen = 0
        session.connect(origin: .user)
        // task-owner: the wait under test; the loop below drives its clock until it ends
        let wait = Task { @MainActor in ended.up = await session.linkUp(within: CloudStartSession.connectWait, clock: clock) }
        while ended.up == nil {
            do { try await clock.waitForSleeper(within: .milliseconds(500)) } catch { continue }
            while seen < session.connects, await openings.next() != nil { seen += 1 }
            _ = await CloudWait.holds(within: .seconds(10)) { session.linkEnded != nil }
            for _ in 0..<8 { await Task.yield() } // the wait sees the refusal before time moves
            guard ended.up == nil, let next = clock.sleeperDeadlines.min() else { continue }
            clock.advance(by: max(.zero, clock.now.duration(to: next)))
        }
        await wait.value
        let opens = await resolver.opens
        print("bench refused-start: virtual_wait=\(clock.now.offset) serve_starts=\(opens) redials=\(opens - 1) up=\(ended.up ?? false)")
        #expect(clock.now.offset < .seconds(1), "the wait ends on the refusal, not at its deadline")
        #expect(opens == 1, "no serve is started again")
    }

    @Test func aStartWhoseHelperCannotStartEndsAtOnceWithTheReason() async throws {
        let resolver = RefusingResolver()
        let session = Self.session(resolver)
        let id = session.machineID
        defer { session.disconnect() }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: "tab-1"), origin: .user)
        let clock = ContinuousClock(), began = clock.now
        do {
            _ = try await CloudMove.connected(session, invocation)
            Issue.record("a machine whose helper cannot start connected")
        } catch let failure as CloudMove.Failure {
            #expect(failure.message == CloudMoveStrings.notConnected("Refused VM", because: "the Keychain refused the carrier key (-128)"))
            #expect(failure.retry == .move(machineID: id), "the card offers Retry")
        }
        // Without the fix the wait connects again for its whole 180 s (the suite's time limit fails it first).
        #expect(began.duration(to: clock.now) < .seconds(30))
        #expect(await resolver.opens == 1, "a helper that cannot start is not started again by the wait")
        #expect(session.linkRefusal.refused)

        // A Retry (a new connect) asks the link again: the refusal is that connect's, not kept for good.
        do {
            _ = try await CloudMove.connected(session, invocation)
            Issue.record("a machine whose helper cannot start connected")
        } catch is CloudMove.Failure {}
        #expect(await resolver.opens == 2)
    }
}
