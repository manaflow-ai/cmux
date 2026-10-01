import CmuxIrxTransport

actor IrxControlReleaseProbe {
    private(set) var count = 0
    private(set) var closeCodes: [IrxCloseCode] = []
    private(set) var retiresConnections: [Bool] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func record(closeCode: IrxCloseCode, retiresConnection: Bool) {
        count += 1
        closeCodes.append(closeCode)
        retiresConnections.append(retiresConnection)
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Observe a release that late establishment cleanup reports after the
    /// closed owner's caller has already returned.
    func waitForRelease() async throws -> Bool {
        try await withIrxDeadline(.seconds(2), onTimeout: { await self.resumeReleaseWaiters() }) {
            await self.awaitRelease()
        } == true
    }

    private func awaitRelease() async -> Bool {
        if count > 0 { return true }
        await withCheckedContinuation { releaseWaiters.append($0) }
        return count > 0
    }

    private func resumeReleaseWaiters() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
