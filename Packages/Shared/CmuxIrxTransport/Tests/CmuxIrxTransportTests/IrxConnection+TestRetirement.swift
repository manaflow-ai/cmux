@testable import CmuxIrxTransport

extension IrxConnection {
    /// Observe actual late cleanup, without requiring a cancelled caller to await it.
    func waitForTestRetirement() async throws -> Bool {
        try await withIrxDeadline(.seconds(2), onTimeout: {
            await self.close(code: .userRequested, origin: .local)
        }) {
            _ = await self.termination()
            return true
        } == true
    }
}
