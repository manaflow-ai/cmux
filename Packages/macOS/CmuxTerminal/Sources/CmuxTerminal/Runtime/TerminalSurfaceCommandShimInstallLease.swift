internal import Foundation

/// Owns one gate permit and rejects later work after its deadline expires.
actor TerminalSurfaceCommandShimInstallLease {
    private let gate: TerminalSurfaceCommandShimInstallGate
    private var isInvalidated = false
    private var token: UUID?

    init(gate: TerminalSurfaceCommandShimInstallGate) {
        self.gate = gate
    }

    func acquire() async -> UUID? {
        guard let token = await gate.acquire() else { return nil }
        guard !isInvalidated else {
            await gate.release(token)
            return nil
        }
        self.token = token
        return token
    }

    func invalidate() async {
        isInvalidated = true
        if let token {
            await gate.rejectAcquisitions(untilReleaseOf: token)
        }
    }

    func release(_ token: UUID) async {
        if self.token == token {
            self.token = nil
        }
        await gate.release(token)
    }
}
