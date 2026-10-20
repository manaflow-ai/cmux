import Foundation

extension Clock where Duration == Swift.Duration {
    func authTokenDeadline(after duration: Duration) -> AuthTokenDeadline {
        let end = now.advanced(by: duration)
        return AuthTokenDeadline(
            hasExpired: { self.now >= end },
            remaining: { max(.zero, self.now.duration(to: end)) },
            wait: { try await self.sleep(until: end, tolerance: nil) }
        )
    }
}
