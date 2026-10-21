import Foundation
import Testing
@testable import CmuxMobileModel

/// verify/perf-latency.md: the cached list a launch shows is reconciled in
/// place with the Mac's first live answer, and a still-valid stored token
/// goes out without waiting for Stack's refresh.
@Suite struct LaunchReconcileTests {
    static func ws(_ id: String, _ mac: String) -> Workspace {
        Workspace(id: id, macID: mac, title: id, directory: "~", tabs: [], lastActivityAt: Date(timeIntervalSince1970: 0))
    }

    @Test func liveAnswerKeepsTheMacsBlockInPlace() {
        let current = [Self.ws("a1", "A"), Self.ws("a2", "A"), Self.ws("b1", "B")]
        let next = [Self.ws("a2", "A"), Self.ws("a1", "A"), Self.ws("a3", "A")]
        let merged = AppStore.reconciled(current, macID: "A", with: next, keeping: [])
        // The Mac's rows stay ahead of B's (the old merge put them after every other Mac's).
        #expect(merged.map(\.id) == ["a2", "a1", "a3", "b1"])
    }

    @Test func otherMacsAndPendingRowsDoNotMove() {
        let current = [Self.ws("b1", "B"), Self.ws("p", "A"), Self.ws("a1", "A"), Self.ws("c1", "C")]
        let merged = AppStore.reconciled(current, macID: "A", with: [Self.ws("a1", "A"), Self.ws("a2", "A")], keeping: ["p"])
        #expect(merged.map(\.id) == ["b1", "p", "a1", "a2", "c1"])
    }

    @Test func aMacWithNoCachedRowsAppends() {
        let merged = AppStore.reconciled([Self.ws("b1", "B")], macID: "A", with: [Self.ws("a1", "A")], keeping: [])
        #expect(merged.map(\.id) == ["b1", "a1"])
        #expect(AppStore.reconciled([Self.ws("a1", "A"), Self.ws("b1", "B")], macID: "A", with: [], keeping: []).map(\.id) == ["b1"])
    }

    @Test func identicalAnswerIsNoChange() {
        let current = [Self.ws("a1", "A"), Self.ws("b1", "B")]
        #expect(AppStore.reconciled(current, macID: "A", with: [Self.ws("a1", "A")], keeping: []) == current)
    }

    static func jwt(exp: TimeInterval?) -> String {
        var claims: [String: Any] = ["sub": "u1", "iat": 1_000]
        if let exp { claims["exp"] = exp }
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let b64 = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJFUzI1NiJ9.\(b64).sig"
    }

    @Test func storedTokenIsUsableUntilAMinuteBeforeItsExpiry() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(AccessTokenExpiry(token: Self.jwt(exp: 10_000 + 600)).isUsable(at: now))
        #expect(AccessTokenExpiry(token: Self.jwt(exp: 10_000 + 61)).isUsable(at: now))
        #expect(!AccessTokenExpiry(token: Self.jwt(exp: 10_000 + 59)).isUsable(at: now))
        #expect(!AccessTokenExpiry(token: Self.jwt(exp: 9_000)).isUsable(at: now))
        #expect(AccessTokenExpiry(token: Self.jwt(exp: 10_600)).expiresAt == Date(timeIntervalSince1970: 10_600))
    }

    @Test func unreadableTokensAreNeverUsedWithoutStack() {
        let now = Date()
        #expect(!AccessTokenExpiry(token: Self.jwt(exp: nil)).isUsable(at: now))
        #expect(!AccessTokenExpiry(token: "opaque-token").isUsable(at: now))
        #expect(!AccessTokenExpiry(token: "a.%%%.c").isUsable(at: now))
        #expect(AccessTokenExpiry(token: "").expiresAt == nil)
    }
}
