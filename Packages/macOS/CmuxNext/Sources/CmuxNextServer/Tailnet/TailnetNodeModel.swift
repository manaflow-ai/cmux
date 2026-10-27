public import Foundation
public import Observation

/// Settings > Accounts > "This Mac on Your Tailnet" (Labs): the daemon's own tailnet node, signed
/// in the way Tailscale's apps do it (a sign-in link the person opens in the browser), its address,
/// a Pair code for another Mac, and who may connect. The App feeds it the node's state
/// (`tailnet.state`); the buttons run ``TailnetNodeServices``. Default deny: only the person's own
/// Tailscale account may connect until they turn "Limit access" off.
@MainActor @Observable
public final class TailnetNodeModel {
    public nonisolated enum Phase: Equatable, Sendable {
        /// No node to sign in: the daemon has none (`not_built`), or no daemon answers.
        case unavailable
        case signedOut
        case starting
        /// Sign-in started: the person finishes it in the browser (`url`, Reopen).
        case waitingForBrowser(url: String)
        /// Signed in, but the tailnet's admin must approve the device.
        case needsApproval
        case signedIn(address: String, login: String?)
        case failed(String)
    }

    public private(set) var phase: Phase = .unavailable
    /// Who may connect. Read only for now: the node does not read the app's choice yet, so it stays
    /// owner-only (the switch is shown on and disabled until it does).
    public private(set) var access: TailnetAccess
    /// The Pair code shown after Pair: this Mac's address and a fresh ticket.
    public private(set) var pairCode: TailnetPairCode?
    /// The failure of the last button, shown under the card until the next one.
    public private(set) var actionError: String?
    /// True while a button's request runs (buttons are off meanwhile).
    public private(set) var busy = false
    /// The person pressed Sign In and the node has not signed in since: only then is a sign-in
    /// link shown (a link the node offers by itself is not opened for them).
    @ObservationIgnored private var signInRequested = false
    /// Stream snapshots and local cancellation invalidate replies from an older state.
    @ObservationIgnored private var revision: UInt64 = 0
    /// Pair validity changes only with its identity, a local dismissal or a disconnected read.
    @ObservationIgnored private var pairRevision: UInt64 = 0
    @ObservationIgnored private var openSignInLink = false

    @ObservationIgnored private let services: TailnetNodeServices

    public init(services: TailnetNodeServices) {
        self.services = services
        access = services.loadAccess() ?? TailnetAccess()
    }

    /// The node's state changed (a `tailnet.state` item or a button's answer).
    public func apply(_ state: TailnetNodeState) {
        revision &+= 1
        set(Self.phase(of: state, signInRequested: signInRequested))
        if case .signedIn = phase {
            signInRequested = false
            openSignInLink = false
        } else if openSignInLink, case .waitingForBrowser(let url) = phase {
            openSignInLink = false
            services.openURL(url)
        }
    }

    /// The daemon has no node, or the connection to it ended. Changes nothing when already so, so
    /// a page that reads the card while the daemon is away does not wake itself again.
    public func markUnavailable() {
        revision &+= 1
        pairRevision &+= 1
        signInRequested = false
        openSignInLink = false
        set(.unavailable)
        if pairCode != nil { pairCode = nil }
    }

    /// Writes `phase` only when it changes (Observation wakes readers on every write).
    private func set(_ next: Phase) {
        if phase != next {
            pairRevision &+= 1
            phase = next
            if pairCode != nil { pairCode = nil }
        }
    }

    /// Sign In (and Reopen): start the node's login and open its link in the browser.
    public func signIn() async {
        guard !busy else { return }
        if case .waitingForBrowser(let url) = phase { return services.openURL(url) }
        signInRequested = true
        openSignInLink = true
        let expected = revision
        if let state = await run(services.loginStart, isCurrent: { self.revision == expected }) { apply(state) }
    }

    /// Cancel on the waiting state: the link stays unused; the node keeps waiting until Sign In.
    public func cancelSignIn() {
        revision &+= 1
        signInRequested = false
        openSignInLink = false
        if case .waitingForBrowser = phase { set(.signedOut) }
    }

    public func signOut() async {
        guard !busy else { return }
        signInRequested = false
        openSignInLink = false
        let expected = revision
        guard let state = await run(services.logout, isCurrent: { self.revision == expected }) else { return }
        apply(state)
    }

    /// Pair: a single-use client ticket for this Mac's address, shown as a QR code and a link.
    public func pair() async {
        guard !busy, case .signedIn(let address, _) = phase else { return }
        let expected = pairRevision
        guard let ticket = await run({ try await self.services.mintTicket(address) },
                                    isCurrent: { self.pairRevision == expected }) else { return }
        pairCode = TailnetPairCode(address: address, ticket: ticket)
        if pairCode == nil { actionError = TailnetNodeStrings.pairFailed }
    }

    public func closePair() {
        pairRevision &+= 1
        if pairCode != nil { pairCode = nil }
    }

    private func run<T>(_ body: () async throws -> T, isCurrent: () -> Bool) async -> T? {
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            let result = try await body()
            return isCurrent() ? result : nil
        } catch {
            if isCurrent() { actionError = (error as? any LocalizedError)?.errorDescription ?? String(describing: error) }
            return nil
        }
    }

    /// The card's phase for `state`. A sign-in link shows only after the person asked for one.
    nonisolated static func phase(of state: TailnetNodeState, signInRequested: Bool) -> Phase {
        switch state.state {
        case "running":
            guard let address = state.dnsName.flatMap(TailnetPairCode.canonicalAddress) else { return .starting }
            return .signedIn(address: address, login: state.owner?.loginName)
        case "needs_login":
            guard signInRequested, let url = state.browseToURL, url.hasPrefix("https://") else { return .signedOut }
            return .waitingForBrowser(url: url)
        case "needs_machine_auth": return .needsApproval
        case "starting", "no_state": return signInRequested ? .starting : .signedOut
        case "not_started", "stopped": return .signedOut
        default: return .failed(state.error ?? state.state)
        }
    }
}

/// What the card does outside itself, so its flow runs the same in tests.
public struct TailnetNodeServices {
    public var loginStart: () async throws -> TailnetNodeState
    public var logout: () async throws -> TailnetNodeState
    /// Opens the sign-in link in the person's browser.
    public var openURL: (String) -> Void
    /// Mints a single-use `client` ticket that redeems at `address` (`cmux host ticket new`).
    public var mintTicket: (_ address: String) async throws -> String
    public var loadAccess: () -> TailnetAccess?

    public init(loginStart: @escaping () async throws -> TailnetNodeState, logout: @escaping () async throws -> TailnetNodeState,
                openURL: @escaping (String) -> Void, mintTicket: @escaping (String) async throws -> String,
                loadAccess: @escaping () -> TailnetAccess?) {
        self.loginStart = loginStart
        self.logout = logout
        self.openURL = openURL
        self.mintTicket = mintTicket
        self.loadAccess = loadAccess
    }
}
