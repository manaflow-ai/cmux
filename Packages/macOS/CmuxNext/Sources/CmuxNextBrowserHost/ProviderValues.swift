import CryptoKit
import Foundation

/// The per-launch provider secret. Never printed: descriptions are redacted.
public nonisolated struct ProviderSecret: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { "ProviderSecret(<redacted>)" }
    public var debugDescription: String { description }

    /// What the relay credential signs: `RELAY_CREDENTIAL_CONTEXT` in cmux-browser-host provider.rs.
    static let relayCredentialContext = Data("cmux-chromium-host-relay-v1".utf8)

    /// The credential of the Chromium Host's relay link: HMAC-SHA256 of
    /// ``relayCredentialContext`` keyed by this secret's UTF-8 bytes, as 64 lowercase hex digits
    /// (`ProviderSecret::relay_credential` in provider.rs). It opens a relay link and no provider, so the
    /// app hands it, never the secret, to its Chromium Host.
    public var relayCredential: ProviderSecret {
        let key = SymmetricKey(data: Data(value.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Self.relayCredentialContext, using: key)
        let digits = Array("0123456789abcdef")
        var hex = ""
        hex.reserveCapacity(64)
        for byte in code {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0f)])
        }
        return ProviderSecret(hex)
    }
}

/// A tab the app renders (`TabAnnounce` in cmux-browser-host provider.rs).
public nonisolated struct ProviderTabAnnounce: Hashable, Sendable {
    public var targetID: String
    /// `webkit` or `cef`.
    public var engine: String
    public var workspace: String
    public var profile: String
    public var url: String
    public var title: String
    public var visible: Bool
    /// View points per CSS px the tab's emulation applies (`inputScale`, cx-mogig); 1 for none.
    public var inputScale: Double
    /// The tab's emulation has touch on (`touch`, cx-3ny35).
    public var touch: Bool

    public init(targetID: String, engine: String, workspace: String, profile: String, url: String, title: String, visible: Bool,
                inputScale: Double = 1, touch: Bool = false) {
        self.targetID = targetID
        self.engine = engine
        self.workspace = workspace
        self.profile = profile
        self.url = url
        self.title = title
        self.visible = visible
        self.inputScale = inputScale
        self.touch = touch
    }
}

/// An automation lease on a tab (`Lease` in provider.rs): the app shows it
/// as a "driven by" badge and never shows a lease it did not receive.
public nonisolated struct ProviderLease: Hashable, Sendable {
    public var session: String
    public var actor: String
    public var onBehalfOf: String?
    public var origin: String
    public var label: String
    public var sinceMs: UInt64
    /// The host's lease state (plans/cmux-next/automation-lease.md), passed
    /// through unchanged: the host owns the state machine, the app never
    /// interprets it, and a state this app does not know is kept as it is.
    public var state: String?
    /// The holder's cmux terminal (`term_…`) when its client named one, so the
    /// cursor takes that agent's presence color (cx-gg84). Display only.
    public var terminal: String?

    public init(session: String, actor: String, onBehalfOf: String? = nil, origin: String, label: String, sinceMs: UInt64,
                state: String? = nil, terminal: String? = nil) {
        self.session = session
        self.actor = actor
        self.onBehalfOf = onBehalfOf
        self.origin = origin
        self.label = label
        self.sinceMs = sinceMs
        self.state = state
        self.terminal = terminal
    }
}
