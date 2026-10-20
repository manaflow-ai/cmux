import Foundation

/// The passkey hand-off (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.2):
/// an agent at a passkey step raises a request instead of starting the
/// ceremony in a background tab, where WebKit rejects it ("The document is
/// not focused") and Chromium refuses a hidden page.
///
/// A tab already in front of the person triggers at once. Otherwise the
/// host posts a banner; the person's click (``answer(_:)``) reveals the tab,
/// focused, and only then runs the trigger, so the engine shows Touch ID
/// and the person only touches the sensor. A request runs once, lapses after
/// `ttl`, and a newer request for the same tab replaces it.
///
/// ```swift
/// let requests = BrowserPasskeyRequests(host: appHost)
/// let raised = try await requests.raise(tabID: "tab_1", agent: "Chief", site: "npmjs.com") {
///     try await clickSignInButton()
/// }
/// // raised.status == .pending; the banner click calls:
/// _ = try await requests.answer(raised.id)
/// ```
///
/// Tests pass a recording ``BrowserPasskeyHost`` and a clock they advance.
public actor BrowserPasskeyRequests {
    /// What ``raise(tabID:agent:site:reason:trigger:)`` answers.
    public struct Raised: Sendable, Hashable {
        /// The request id.
        public var id: String
        /// `pending` (a banner asks the person) or `triggered` (the tab was in front).
        public var status: BrowserPasskeyStatus
    }

    private struct Pending {
        var request: BrowserPasskeyRequest
        var expires: ContinuousClock.Instant
        var trigger: @Sendable () async throws -> Void
    }

    private let host: any BrowserPasskeyHost
    private let ttl: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var pending: [String: Pending] = [:]

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
    ///
    /// - Parameters:
    ///   - tabID: the browser tab the ceremony runs in.
    ///   - agent: the asking agent's display name (the banner names it).
    ///   - site: the tab URL's host (the banner names it).
    ///   - reason: the agent's one-line reason, nil for none.
    ///   - trigger: starts the ceremony in the page (clicks its passkey button); runs at most once,
    ///     only while the tab is in front of the person.
    /// - Returns: the request id and `triggered` (the tab was in front) or `pending`.
    /// - Throws: what `trigger` throws when it ran at once.
    public func raise(tabID: String, agent: String, site: String, reason: String? = nil,
                      trigger: @escaping @Sendable () async throws -> Void) async throws -> Raised {
        let instant = now()
        let replaced = pending.filter { $0.value.request.tabID == tabID || $0.value.expires <= instant }.map(\.key).sorted()
        for id in replaced { pending[id] = nil }
        for id in replaced { await host.withdraw(id) }
        let id = UUID().uuidString
        if await host.isInFront(tabID: tabID) {
            try await trigger()
            return Raised(id: id, status: .triggered)
        }
        let request = BrowserPasskeyRequest(id: id, tabID: tabID, agent: agent, site: site, reason: reason)
        pending[id] = Pending(request: request, expires: instant + ttl, trigger: trigger)
        await host.post(request)
        return Raised(id: id, status: .pending)
    }

    /// The person clicked request `id`: reveals its tab, then runs its trigger once.
    ///
    /// - Returns: `triggered`, `expired` (nothing ran, its banner is withdrawn) or `unknown`
    ///   (answered already, replaced, or never raised).
    /// - Throws: when the tab is gone or the trigger fails.
    public func answer(_ id: String) async throws -> BrowserPasskeyStatus {
        guard let request = pending.removeValue(forKey: id) else { return .unknown }
        guard now() < request.expires else {
            await host.withdraw(id)
            return .expired
        }
        try await host.reveal(tabID: request.request.tabID)
        try await request.trigger()
        return .triggered
    }

    /// Whether request `id` still waits for the person (`pending`), else `unknown` or `expired`.
    public func status(_ id: String) -> BrowserPasskeyStatus {
        guard let request = pending[id] else { return .unknown }
        return now() < request.expires ? .pending : .expired
    }
}
