@testable import CmuxIrxTransport

actor IrxReconnectDialSequence {
    let stalled: IrxReconnectTestSession
    let recovered: IrxReconnectTestSession
    let gate = IrxReconnectDialGate()
    let failFirst: Bool
    private(set) var count = 0

    init(stalled: IrxReconnectTestSession, recovered: IrxReconnectTestSession, failFirst: Bool = false) {
        self.stalled = stalled
        self.recovered = recovered
        self.failFirst = failFirst
    }

    func dial() async throws -> IrxClientSession {
        count += 1
        if failFirst {
            if count == 1 { throw IrxConnectionError.closed(nil) }
            await gate.wait()
            return recovered.session
        }
        if count == 1 {
            await gate.wait()
            return stalled.session
        }
        return recovered.session
    }
}
