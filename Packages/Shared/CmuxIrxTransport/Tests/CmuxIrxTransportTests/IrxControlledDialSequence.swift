@testable import CmuxIrxTransport

/// Parks selected native results independently, without observing cancellation.
actor IrxControlledDialSequence {
    let gates: [IrxReconnectDialGate]
    private let sessions: [IrxClientSession]
    private(set) var count = 0

    init(sessions: [IrxClientSession], gates: [IrxReconnectDialGate] = []) {
        self.sessions = sessions
        self.gates = gates
    }

    func dial() async -> IrxClientSession {
        let index = count
        count += 1
        if index < gates.count { await gates[index].wait() }
        return sessions[min(index, sessions.count - 1)]
    }
}
