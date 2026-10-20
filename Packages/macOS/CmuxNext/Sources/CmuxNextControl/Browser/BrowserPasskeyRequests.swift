import Foundation

/// The passkey hand-off (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.2):
/// an agent at a passkey step raises a request instead of starting the
/// ceremony in a background tab, where the engine refuses it.
public actor BrowserPasskeyRequests {
    /// What ``raise(tabID:agent:site:reason:trigger:)`` answers.
    public struct Raised: Sendable, Hashable {
        /// The request id.
        public var id: String
        /// `pending` (a banner asks the person) or `triggered` (the tab was in front).
        public var status: BrowserPasskeyStatus
    }

    private let host: any BrowserPasskeyHost
    private let ttl: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - host: the app's panes, windows and banners.
    ///   - ttl: how long a request waits for the person (default 5 minutes, about a sign-in page's own timeout).
    ///   - now: the clock; tests pass one they advance.
    public init(host: any BrowserPasskeyHost, ttl: Duration = .seconds(300),
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.host = host
        self.ttl = ttl
        self.now = now
    }

    /// Raises a request for tab `tabID`.
    public func raise(tabID: String, agent: String, site: String, reason: String? = nil,
                      trigger: @escaping @Sendable () async throws -> Void) async throws -> Raised {
        Raised(id: UUID().uuidString, status: .pending)
    }

    /// The person clicked request `id`.
    public func answer(_ id: String) async throws -> BrowserPasskeyStatus {
        .unknown
    }
}
