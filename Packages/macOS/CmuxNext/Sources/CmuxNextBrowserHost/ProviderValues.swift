import Foundation

/// The per-launch provider secret. Never printed: descriptions are redacted.
public nonisolated struct ProviderSecret: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { "ProviderSecret(<redacted>)" }
    public var debugDescription: String { description }
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

    public init(targetID: String, engine: String, workspace: String, profile: String, url: String, title: String, visible: Bool) {
        self.targetID = targetID
        self.engine = engine
        self.workspace = workspace
        self.profile = profile
        self.url = url
        self.title = title
        self.visible = visible
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

    public init(session: String, actor: String, onBehalfOf: String? = nil, origin: String, label: String, sinceMs: UInt64,
                state: String? = nil) {
        self.session = session
        self.actor = actor
        self.onBehalfOf = onBehalfOf
        self.origin = origin
        self.label = label
        self.sinceMs = sinceMs
        self.state = state
    }
}
