import CmuxNextHomeModel
import Foundation

/// The card's state machine (cmux-home-rules `compose.mcpConnect.step`): the person's choices move
/// it, the daemon's answers move it, and nothing else does. The host sends what ``effect`` names to
/// the acpmux daemon on the person's own connection (the only one whose answer counts). The key and
/// the tools stay here; Rust learns only whether a key is empty.
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
    /// ``phase``'s name in `compose.mcpConnect.step`.
    private var rule = "ask"

    public init(card: McpConnectCard) {
        self.card = card
        scope = card.proposedScope
    }

    /// The person picks who gets the server (only while asking).
    public mutating func choose(_ scope: McpConnectCard.Scope) { _ = step(Event(kind: "choose", scope: scope.rawValue)) }
    /// Connect: approve with the chosen scope, then sign in or ask for the key.
    public mutating func connect() -> [Effect] { step(Event(kind: "connect")) }
    /// The key from the private field. An empty key connects only an optional-key server.
    public mutating func submit(_ key: McpConnectKey) -> [Effect] { step(Event(kind: "submit", empty: key.isEmpty), key: key) }
    /// Cancel (any time before connected).
    public mutating func cancel() -> [Effect] { step(Event(kind: "cancel")) }
    /// The daemon saw the sign-in finish.
    public mutating func signedIn() { _ = step(Event(kind: "signedIn")) }
    /// The daemon connected and listed the tools.
    public mutating func connected(_ tools: [McpConnectCard.Tool]) { _ = step(Event(kind: "connected"), tools: tools) }
    /// The daemon failed (sign-in refused, server down, metadata refused).
    public mutating func failed(_ reason: String) { _ = step(Event(kind: "failed"), reason: reason) }

    private struct Request: Encodable { var phase: String, scope: String, auth: Auth, event: Event }
    private struct Auth: Encodable { var kind: String; var optional = false }
    private struct Event: Encodable { var kind: String; var scope = ""; var empty = false }
    private struct Answer: Decodable { var phase: String, scope: String, effects: [Sent] }
    private struct Sent: Decodable { var kind: String, scope: String? }

    /// One step through the Rust rules; the key, the tools and the reason stay on this side.
    private mutating func step(_ event: Event, key: McpConnectKey? = nil, tools: [McpConnectCard.Tool] = [], reason: String = "") -> [Effect] {
        let auth = switch card.auth {
        case .none: Auth(kind: "none")
        case .oauth: Auth(kind: "oauth")
        case .device: Auth(kind: "device")
        case .key(_, let optional): Auth(kind: "key", optional: optional)
        }
        let unmoved = Answer(phase: rule, scope: scope.rawValue, effects: [])
        let answer = HomeComposeRules().call("mcpConnect.step", Request(phase: rule, scope: scope.rawValue, auth: auth, event: event), fallback: unmoved)
        scope = McpConnectCard.Scope(rawValue: answer.scope) ?? scope
        if answer.phase != rule || event.kind == "failed" {
            rule = answer.phase
            phase = switch answer.phase {
            case "enterKey": .enterKey
            case "signingIn": .signingIn
            case "connecting": .connecting
            case "connected": .connected(tools: tools)
            case "declined": .declined
            case "failed": .failed(reason)
            default: .ask
            }
        }
        return answer.effects.compactMap { sent -> Effect? in
            switch sent.kind {
            case "approve": .approve(scope: sent.scope.flatMap(McpConnectCard.Scope.init(rawValue:)) ?? scope)
            case "decline": .decline
            case "submitKey": key.map(Effect.submitKey)
            case "beginSignIn": .beginSignIn
            default: nil
            }
        }
    }
}
