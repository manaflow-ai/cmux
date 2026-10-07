import CmuxLink
import Testing

@Suite("LinkStateMachine")
struct LinkStateMachineTests {
    let direct = LinkPath(kind: .direct, carrier: .direct)
    let turn = LinkPath(kind: .turn, carrier: .webrtc)

    @Test("dial, degrade, roam, resume, close")
    func lifecycle() {
        var machine = LinkStateMachine()
        let changed1 = machine.apply(.attemptStarted(1))
        #expect(changed1)
        #expect(machine.state == .connecting(attempt: 1))
        let changed2 = machine.apply(.attemptStarted(2))
        #expect(changed2)
        let changed3 = machine.apply(.connected(direct))
        #expect(changed3)
        #expect(machine.state == .connected(direct))
        let changed4 = machine.apply(.health(.degraded(.highLatency)))
        #expect(changed4)
        #expect(machine.state == .degraded(direct, .highLatency))
        let changed5 = machine.apply(.pathChanged(turn))
        #expect(changed5)
        #expect(machine.state == .degraded(turn, .highLatency))
        let changed6 = machine.apply(.health(.good))
        #expect(changed6)
        #expect(machine.state == .connected(turn))
        let changed7 = machine.apply(.transportLost(attempt: 1))
        #expect(changed7)
        #expect(machine.state == .reconnecting(attempt: 1, lastPath: turn))
        let changed8 = machine.apply(.attemptStarted(3))
        #expect(changed8)
        #expect(machine.state == .reconnecting(attempt: 3, lastPath: turn))
        let changed9 = machine.apply(.connected(direct))
        #expect(changed9)
        let changed10 = machine.apply(.close(.local))
        #expect(changed10)
        #expect(machine.state == .closed(.local))
    }

    @Test("closed is terminal")
    func closedIsTerminal() {
        var machine = LinkStateMachine(state: .closed(.remote))
        for event: LinkStateEvent in [.attemptStarted(1), .connected(direct), .close(.local), .transportLost(attempt: 1)] {
            let changed11 = machine.apply(event)
            #expect(!changed11)
        }
        #expect(machine.state == .closed(.remote))
    }

    @Test("invalid transitions are ignored")
    func invalid() {
        var machine = LinkStateMachine()
        let changed12 = machine.apply(.pathChanged(direct))
        #expect(!changed12)
        let changed13 = machine.apply(.health(.degraded(.congested)))
        #expect(!changed13)
        let changed14 = machine.apply(.transportLost(attempt: 1))
        #expect(!changed14)
        #expect(machine.state == .idle)
        machine.apply(.connected(direct))
        let changed15 = machine.apply(.attemptStarted(1))
        #expect(!changed15)
        let changed16 = machine.apply(.health(.good))
        #expect(!changed16)
        let changed17 = machine.apply(.connected(direct))
        #expect(!changed17)
    }

    @Test("badge shows relayed and slow paths")
    func badge() {
        #expect(PathBadge(path: turn).shouldShow)
        #expect(PathBadge(path: LinkPath(kind: .relay, carrier: .doRelay)).shouldShow)
        #expect(!PathBadge(path: direct, rtt: .milliseconds(20)).shouldShow)
        #expect(PathBadge(path: direct, rtt: .milliseconds(80)).shouldShow)
        #expect(PathBadge(path: direct, rtt: .microseconds(12_500)).rttMilliseconds == 12.5)
    }

    @Test("backoff doubles and caps")
    func backoff() {
        let backoff = Backoff(initial: .milliseconds(100), maximum: .milliseconds(700))
        #expect((1...5).map(backoff.delay(after:)) == [
            .milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(700), .milliseconds(700),
        ])
    }

    @Test("policy ranks paths in order")
    func policy() {
        let policy = PathPolicy()
        #expect(PathKind.allCases.map(policy.rank(of:)) == [0, 1, 2, 3])
        #expect(PathPolicy(order: [.p2p, .direct]).rank(of: .relay) == 2)
    }
}
