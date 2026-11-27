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

    /// A chat its own connection or the organization's key serves never uses this Mac's gateway: its start waits for
    /// none, even when the gateway cannot come up (the production probe's starts sat out the whole 10 s deadline).
    @Test func aStartServedElsewhereWaitsForNoGateway() async {
        let clock = ManualClock()
        let children = Children([[]]) // never comes online
        let gateway = make(children, clock: clock)
        gateway.start()
        let beside = gateway.onlineBeside(within: .seconds(10)) { .organization(family: "claude") }
        #expect(await beside.value) // no deadline advanced: answered at once
        #expect(gateway.state == .starting)
    }

    /// A route that may use it (nothing else read as serving the chat): the start still waits for the gateway, up to its deadline.
    @Test func aStartOnTheMacsGatewayStillWaitsForIt() async throws {
        let clock = ManualClock()
        let children = Children([[]])
        let gateway = make(children, clock: clock)
        gateway.start()
        let beside = gateway.onlineBeside(within: .seconds(10)) { .fallback }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(10))
        #expect(await beside.value == false)
    }

    /// The team's gateway read online and serving while this Mac's is still starting, or running but dialing again: another
    /// gateway serves the turn, so the start waits for none (the production probe's first start after sign-in sat out the
    /// whole 10 s deadline, run 45965760313). Bounded in real time, so a start that waits again fails here, not hangs.
    @Test(arguments: [nil, #"{"event":"offline","reason":"disconnected"}"#])
    func aStartTheTeamsOnlineGatewayServesWaitsForNoneWhileThisOneIsNotOnline(line: String?) async throws {
        let clock = ManualClock()
        let children = Children([line.map { [$0] } ?? []]) // never comes online
        let gateway = make(children, clock: clock)
        gateway.start()
        let expected: PersonalGateway.State = line == nil ? .starting : .offline("disconnected")
        for _ in 0..<1000 where gateway.state != expected { await Task.yield() }
        try #require(gateway.state == expected)
        let beside = gateway.onlineBeside(within: .seconds(10)) { .gateway(family: "claude") }
        #expect(await answer(beside) == true) // no deadline advanced: answered at once
        #expect(gateway.state == expected) // left as it was, not restarted
    }

    /// `beside`'s answer, or nil when it gave none within `bound` of real time: a test whose start should answer at once
    /// fails on nil rather than hanging on a ManualClock deadline nothing advances.
    private func answer(_ beside: CloudStartBeside<Bool>, within bound: Duration = .seconds(5)) async -> Bool? {
        let (first, send) = AsyncStream.makeStream(of: Bool?.self)
        // task-owner: test: the start's answer; left behind only when it misses the bound (the test then fails).
        Task { send.yield(await beside.value) }
        // task-owner: test: the bound; ends the race with nil.
        Task { try? await Task.sleep(for: bound); send.yield(nil) }
        for await answer in first { send.finish(); return answer }
        return nil
    }

    /// Which routes reach this Mac's gateway: only the connection's credential and the organization's key do not.
    @Test func onlyAConnectionOrTheOrganizationsKeyServeWithoutTheMacsGateway() {
        #expect(CloudSetup.Choice.connection(id: "c", family: "claude").servedWithoutMacGateway)
        #expect(CloudSetup.Choice.organization(family: "claude").servedWithoutMacGateway)
        #expect(!CloudSetup.Choice.gateway(family: "claude").servedWithoutMacGateway)
        #expect(!CloudSetup.Choice.fallback.servedWithoutMacGateway)
        #expect(!CloudSetup.Choice.setup(family: "claude", model: nil).servedWithoutMacGateway)
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

    /// Another gateway of the person's took over and the team's gateway serves the chat (the start's choice read it online):
    /// the start waits for none and does not take the machines back (the probe's gateway rows waited 2.5 to 4.4 s on it).
    @Test func aStartTheGatewayThatTookOverServesWaitsForNoRestart() async {
        let children = Children([[#"{"event":"stopped","reason":"replaced"}"#, "EXIT"], [#"{"event":"online"}"#]])
        let gateway = make(children)
        gateway.start()
        #expect(await gateway.ensureOnline(within: .seconds(60)) == false)
        #expect(gateway.state == .replaced)
        let beside = gateway.onlineBeside(within: .seconds(10)) { .gateway(family: "claude") }
        #expect(await beside.value)
        #expect(gateway.state == .replaced)
        #expect(children.live.count == 1, "not taken back")
        // A route the team's gateway does not serve still starts this one again.
        #expect(!gateway.servedElsewhere(.fallback))
        #expect(await gateway.onlineBeside(within: .seconds(60)) { .fallback }.value)
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
