import Testing
@testable import CmuxRemoteSession

@Suite("Remote PTY async close handoff")
struct RemotePTYAsyncCloseOperationGateTests {
    @Test("a queue timeout prevents a late close from starting")
    func timeoutWinsBeforeQueueCallback() {
        let gate = RemotePTYAsyncCloseOperationGate()
        #expect(gate.timeoutBeforeStart())
        #expect(!gate.begin())
        #expect(!gate.complete())
    }

    @Test("a running close owns the continuation until completion")
    func runningCloseWinsOverTimeout() {
        let gate = RemotePTYAsyncCloseOperationGate()
        #expect(gate.begin())
        #expect(!gate.timeoutBeforeStart())
        #expect(gate.complete())
        #expect(!gate.complete())
    }
}
