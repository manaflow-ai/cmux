import CmuxFoundation
import Testing

struct AgentPIDProcessIdentityOrderTests {
    @Test
    func ordersByStartSecondsThenMicroseconds() {
        let base = AgentPIDProcessIdentity(pid: 10, startSeconds: 100, startMicroseconds: 500)
        let laterMicrosecond = AgentPIDProcessIdentity(pid: 11, startSeconds: 100, startMicroseconds: 501)
        let laterSecond = AgentPIDProcessIdentity(pid: 12, startSeconds: 101, startMicroseconds: 0)

        #expect(base.started(before: laterMicrosecond))
        #expect(base.started(before: laterSecond))
        #expect(laterMicrosecond.started(before: laterSecond))
        #expect(!laterSecond.started(before: base))
    }

    @Test
    func identicalStartIsNotEarlier() {
        let first = AgentPIDProcessIdentity(pid: 10, startSeconds: 100, startMicroseconds: 500)
        let second = AgentPIDProcessIdentity(pid: 20, startSeconds: 100, startMicroseconds: 500)

        #expect(!first.started(before: second))
        #expect(!second.started(before: first))
    }
}
