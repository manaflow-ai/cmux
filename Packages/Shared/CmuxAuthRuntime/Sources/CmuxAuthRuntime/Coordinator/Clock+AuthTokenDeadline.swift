import Foundation

extension Clock where Duration == Swift.Duration {
    func authTokenDeadline(after duration: Duration) -> AuthTokenDeadline {
        let end = now.advanced(by: duration)
        let tolerance = duration.authWakeLeeway
        return AuthTokenDeadline(
            hasExpired: { self.now >= end },
            remaining: { max(.zero, self.now.duration(to: end)) },
            // wakeup-allow: deadline one absolute end shared by the phases of a budget; the waiter cancels it
            wait: { try await self.sleep(until: end, tolerance: tolerance) }
        )
    }
}
