import Foundation

/// Bounded waits and user-facing error text for ``CloudTunnelCoordinator``.
extension CloudTunnelCoordinator {
    /// Race `operation` against the clock; the loser is cancelled.
    func withDeadline<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clock = self.clock
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(for: duration)
                throw CloudTunnelError.deadlineExceeded
            }
            guard let first = try await group.next() else {
                throw CloudTunnelError.deadlineExceeded
            }
            group.cancelAll()
            return first
        }
    }

    static func userMessage(for error: any Error) -> String {
        if let tunnelError = error as? CloudTunnelError {
            return tunnelError.description
        }
        let nsError = error as NSError
        if nsError.domain == "NEVPNErrorDomain" || nsError.domain == "NEConfigurationErrorDomain" {
            let format = String(
                localized: "cloudTunnel.error.vpnConfiguration",
                defaultValue: "macOS rejected the VPN configuration (code %d)."
            )
            return String(format: format, nsError.code)
        }
        return nsError.localizedDescription
    }
}
