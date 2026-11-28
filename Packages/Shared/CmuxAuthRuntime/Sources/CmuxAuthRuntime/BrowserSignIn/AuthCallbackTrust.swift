public import Foundation

/// How a token-bearing auth callback reached the app. The flow trusts each
/// route differently, so the caller must say which one delivered the URL.
public enum AuthCallbackDelivery: Sendable, Equatable {
    /// LaunchServices (`application(_:open:)`) or any other route a web page or
    /// local process can trigger. Stateless callbacks need user approval.
    case external
    /// The embedded browser's own after-sign-in handoff, already gated by its
    /// main-frame, user-activated link, same-origin, and own-scheme checks.
    case trustedEmbeddedBrowser
}

/// What a native confirmation dialog shows before an unsolicited, stateless
/// callback is allowed to sign the app in.
public struct UnsolicitedAuthCallbackApprovalRequest: Sendable, Equatable {
    /// Email claimed by the callback's access token, when decodable. Tokens
    /// that do not validate never sign in, so a successful sign-in matches it.
    public let accountEmail: String?
    /// Email of the account that is signed in now, if any.
    public let currentAccountEmail: String?
    /// Whether approving would replace a currently signed-in session.
    public let replacesSignedInSession: Bool

    /// Creates a request.
    public init(accountEmail: String?, currentAccountEmail: String?, replacesSignedInSession: Bool) {
        self.accountEmail = accountEmail
        self.currentAccountEmail = currentAccountEmail
        self.replacesSignedInSession = replacesSignedInSession
    }
}

extension AuthCallbackPayload {
    /// The `email` claim of the access token, read without verification and
    /// used only for display.
    var claimedEmail: String? {
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = (object["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty,
              email.count <= 320 else {
            return nil
        }
        return email
    }
}

/// App-issued callback states that may complete sign-in outside the live
/// popup attempt. Each state expires and is consumed by its first use.
@MainActor
struct HostBrowserIssuedCallbackStates {
    private struct Entry {
        let state: String
        let isExpired: @Sendable () -> Bool
    }

    private var entries: [Entry] = []

    /// Register `state`, replacing an earlier registration of the same value.
    mutating func issue(_ state: String, clock: any Clock<Duration>, lifetime: Duration) {
        remove(state)
        entries.append(Entry(state: state, isExpired: Self.expiry(clock: clock, after: lifetime)))
    }

    /// Remove and report whether `state` was issued and is still unexpired.
    /// Every live entry is compared so timing does not reveal which matched.
    mutating func consume(_ state: String) -> Bool {
        entries.removeAll { $0.isExpired() }
        var matchIndex: Int?
        for (index, entry) in entries.enumerated() where Self.constantTimeEquals(entry.state, state) {
            matchIndex = index
        }
        guard let matchIndex else { return false }
        entries.remove(at: matchIndex)
        return true
    }

    mutating func remove(_ state: String) {
        entries.removeAll { Self.constantTimeEquals($0.state, state) }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// Compares secrets in time that depends only on their lengths.
    nonisolated static func constantTimeEquals(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        if left.count != right.count { difference |= 1 }
        let length = max(left.count, right.count)
        for index in 0 ..< length {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }

    private static func expiry<C: Clock>(clock: C, after lifetime: Duration) -> @Sendable () -> Bool
        where C.Duration == Duration {
        let deadline = clock.now.advanced(by: lifetime)
        return { clock.now >= deadline }
    }
}
