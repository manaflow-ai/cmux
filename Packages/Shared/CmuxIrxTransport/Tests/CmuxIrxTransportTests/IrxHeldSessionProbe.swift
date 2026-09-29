@testable import CmuxIrxTransport

/// Holds one observed native state while the engine installs a replacement.
actor IrxHeldSessionProbe {
    let gate = IrxReconnectDialGate()
    private let heldConnection: IrxConnection
    private var held = false

    init(_ connection: IrxConnection) { heldConnection = connection }

    func isClosed(_ connection: IrxConnection) async -> Bool {
        let closed = await connection.isConnectionClosed()
        if connection === heldConnection, !held {
            held = true
            await gate.wait()
        }
        return closed
    }
}
