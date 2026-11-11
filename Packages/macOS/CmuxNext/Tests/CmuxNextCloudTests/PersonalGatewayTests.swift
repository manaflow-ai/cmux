import CmuxNextCloud
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The app's supervision of the person's own gateway child (``PersonalGateway``): started at sign-in,
/// awaited before a Cloud chat's first turn, restarted after an exit, not fought when another gateway
/// of the person's takes over, and ended at sign-out.
@MainActor
@Suite
struct PersonalGatewayTests {
    /// Gateway children the test drives: each launch takes the next scripted one and is announced.
    @MainActor
    final class Children {
        var scripts: [[String]] = []
        var live: [AsyncStream<String>.Continuation] = []
        let launches: AsyncStream<Int>
        private let announce: AsyncStream<Int>.Continuation

        init(_ scripts: [[String]]) {
            self.scripts = scripts
            (launches, announce) = AsyncStream.makeStream(of: Int.self)
        }

        func launch() -> PersonalGateway.Child {
            let (events, continuation) = AsyncStream.makeStream(of: String.self)
            // A script's last line `EXIT` ends that child after its lines.
            for line in scripts.isEmpty ? [] : scripts.removeFirst() {
                if line == "EXIT" { continuation.finish() } else { continuation.yield(line) }
            }
            live.append(continuation)
            announce.yield(live.count)
            return PersonalGateway.Child(events: events, exited: { 0 }, stop: { continuation.finish() })
        }

        /// The current child writes `line` (and, with `exit`, ends).
        func say(_ line: String, exit: Bool = false) {
            live.last?.yield(line)
            if exit { live.last?.finish() }
        }
    }

    private func make(_ children: Children, clock: ManualClock = ManualClock()) -> PersonalGateway {
        PersonalGateway(launch: { children.launch() }, clock: clock)
    }

    @Test func aCloudChatStartWaitsForTheGatewayToComeOnline() async {
        let children = Children([[#"{"event":"online"}"#]])
        let gateway = make(children)
        gateway.start()
        #expect(await gateway.ensureOnline(within: .seconds(5)))
        #expect(gateway.state == .online)
        // Online already: the next start does not wait.
        #expect(await gateway.ensureOnline(within: .seconds(5)))
    }

    @Test func aGatewayThatDoesNotConnectEndsTheWaitAtItsDeadline() async throws {
        let clock = ManualClock()
        let children = Children([[]])
        let gateway = make(children, clock: clock)
        gateway.start()
        // task-owner: test: the start's wait, ended by the deadline below.
        let wait = Task { await gateway.ensureOnline(within: .seconds(5)) }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(5))
        #expect(await wait.value == false)
    }

    @Test func anotherGatewayTakingOverIsNotFoughtUntilAChatStartsHere() async {
        let children = Children([[#"{"event":"stopped","reason":"replaced"}"#, "EXIT"], [#"{"event":"online"}"#]])
        let gateway = make(children)
        gateway.start()
        // The wait is in place before the child runs (start only schedules it): the replacement ends it.
        #expect(await gateway.ensureOnline(within: .seconds(60)) == false)
        #expect(gateway.state == .replaced)
        #expect(children.live.count == 1, "no restart on its own")
        // A Cloud chat started on this Mac: this Mac takes its machines back.
        #expect(await gateway.ensureOnline(within: .seconds(60)))
        #expect(children.live.count == 2)
    }

    @Test func anExitedGatewayStartsAgainAfterItsBackoff() async throws {
        let clock = ManualClock()
        let children = Children([[#"{"event":"online"}"#], [#"{"event":"online"}"#]])
        let gateway = make(children, clock: clock)
        var launches = children.launches.makeAsyncIterator()
        gateway.start()
        #expect(await launches.next() == 1)
        #expect(await gateway.ensureOnline(within: .seconds(5)))
        children.say(#"{"event":"offline","reason":"disconnected"}"#, exit: true)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        #expect(await launches.next() == 2)
        #expect(await gateway.ensureOnline(within: .seconds(5)))
    }

    @Test func signingOutEndsTheGatewayAndItsWaits() async throws {
        let clock = ManualClock()
        let children = Children([[]])
        let gateway = make(children, clock: clock)
        gateway.start()
        // task-owner: test: a wait the sign-out ends.
        let wait = Task { await gateway.ensureOnline(within: .seconds(60)) }
        // Its deadline sleeps once the wait is registered.
        try await clock.waitForSleeper()
        gateway.stop()
        #expect(await wait.value == false)
        #expect(gateway.state == .stopped)
        #expect(await gateway.ensureOnline(within: .seconds(60)) == false, "signed out: no gateway, no wait")
    }

    @Test func theLiveChildServesThePersonsOwnMachinesFromTheMacsLogins() {
        let args = PersonalGateway.arguments(api: URL(string: "https://api.cmux.dev")!, marker: URL(fileURLWithPath: "/c/personal-gateway-on"))
        #expect(args.prefix(5) == ["inference", "gateway", "--personal", "--mac-logins", "--supervised"])
        #expect(args.contains("/c/personal-gateway-on") && args.contains("https://api.cmux.dev"))
        // The gateway's own default token source (the app's `cmux auth token`): no token flag.
        #expect(!args.contains("--token-file") && !args.contains("--token-command"))
    }
}
