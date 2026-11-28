import CmuxIrxTransport

actor IrxControlReleaseProbe {
    private(set) var count = 0
    private(set) var closeCodes: [IrxCloseCode] = []
    private(set) var retiresConnections: [Bool] = []

    func record(closeCode: IrxCloseCode, retiresConnection: Bool) {
        count += 1
        closeCodes.append(closeCode)
        retiresConnections.append(retiresConnection)
    }
}
