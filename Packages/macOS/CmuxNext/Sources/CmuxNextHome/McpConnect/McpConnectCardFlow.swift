import Foundation

/// The card's state machine, pure so every step has a test: the person's choices move it, the
/// daemon's answers move it, and nothing else does. The host sends what ``effect`` names to the
/// acpmux daemon on the person's own connection (the only one whose answer counts).
public struct McpConnectCardFlow: Equatable, Sendable {
    /// Where the card is.
    public enum Phase: Equatable, Sendable {
        /// The facts and Connect / Cancel.
        case ask
        /// A key server: the private field is shown.
        case enterKey
        /// The sign-in page is open; cmux waits for it to finish.
        case signingIn
        /// Approved and signed in; listing the tools.
        case connecting
        case connected(tools: [McpConnectCard.Tool])
        case declined
        case failed(String)
    }

    /// What the host must send for the step just taken.
    public enum Effect: Equatable, Sendable {
        case none
        /// `_acpmux/mcp_connect_answer {approve: true, scope}`.
        case approve(scope: McpConnectCard.Scope)
        /// `_acpmux/mcp_connect_answer {approve: false}`.
        case decline
        /// `_acpmux/mcp_key_submit`: the key goes to the daemon only, never into this state.
        case submitKey(McpConnectKey)
        /// `_acpmux/mcp_auth_begin`, then open the URL it returns in a cmux browser tab.
        case beginSignIn
    }

    public let card: McpConnectCard
    public private(set) var phase: Phase = .ask
    public private(set) var scope: McpConnectCard.Scope

    public init(card: McpConnectCard) {
        self.card = card
        scope = card.proposedScope
    }

    /// The person picks who gets the server (only while asking).
    public mutating func choose(_ scope: McpConnectCard.Scope) {
        guard phase == .ask else { return }
        self.scope = scope
    }

    /// Connect: approve with the chosen scope, then sign in or ask for the key.
    public mutating func connect() -> [Effect] {
        guard phase == .ask else { return [] }
        switch card.auth {
        case .none:
            phase = .connecting
            return [.approve(scope: scope)]
        case .oauth, .device:
            phase = .signingIn
            return [.approve(scope: scope), .beginSignIn]
        case .key:
            phase = .enterKey
            return [.approve(scope: scope)]
        }
    }

    /// The key from the private field. An empty key connects only an optional-key server.
    public mutating func submit(_ key: McpConnectKey) -> [Effect] {
        guard phase == .enterKey else { return [] }
        if key.isEmpty {
            guard case .key(_, optional: true) = card.auth else { return [] }
            phase = .connecting
            return []
        }
        phase = .connecting
        return [.submitKey(key)]
    }

    /// Cancel (any time before connected).
    public mutating func cancel() -> [Effect] {
        switch phase {
        case .connected, .declined, .failed: return []
        case .ask, .enterKey, .signingIn, .connecting:
            phase = .declined
            return [.decline]
        }
    }

    /// The daemon saw the sign-in finish.
    public mutating func signedIn() {
        guard phase == .signingIn else { return }
        phase = .connecting
    }

    /// The daemon connected and listed the tools.
    public mutating func connected(_ tools: [McpConnectCard.Tool]) {
        guard phase == .connecting || phase == .signingIn else { return }
        phase = .connected(tools: tools)
    }

    /// The daemon failed (sign-in refused, server down, metadata refused).
    public mutating func failed(_ reason: String) {
        switch phase {
        case .connected, .declined: return
        default: phase = .failed(reason)
        }
    }
}
