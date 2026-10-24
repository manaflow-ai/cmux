@testable import CmuxNextPopups

/// A sign-in tab that counts its closes.
final class FakeWebAuthSurface: WebAuthSessionSurface {
    private(set) var closes = 0

    func close() { closes += 1 }
}
