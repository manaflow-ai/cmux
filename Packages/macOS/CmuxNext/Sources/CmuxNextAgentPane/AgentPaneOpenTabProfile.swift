/// The browser profile a New Tab page's pick opens its address in (``AgentPaneOpenTab/profile``):
/// the page's Open in Profile… and Open in New Profile rows (Lawrence 2026-11-05).
public nonisolated enum AgentPaneOpenTabProfile: Equatable, Sendable {
    /// The profile with this id (`default` or a UUID); the host refuses an id it does not know.
    case existing(String)
    /// A profile made for the address: named `name`, else the next default name ("Profile 3").
    case new(name: String?)

    /// The longest profile id or name the page may send.
    static let maximumText = 128

    /// The profile `tab.open`'s params name: `profile` (an id), or `newProfile: true` with an
    /// optional `profileName`; nil when they name none or an id no profile could have.
    init?(params: [String: Any]?) {
        if params?["newProfile"] as? Bool == true {
            let name = (params?["profileName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self = .new(name: name.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maximumText)) })
            return
        }
        guard let id = params?["profile"] as? String, !id.isEmpty, id.count <= Self.maximumText else { return nil }
        self = .existing(id)
    }
}

extension AgentPaneOpenTabProfile {
    /// The id of an ``existing(_:)`` profile; nil for one still to be made.
    public var existingID: String? {
        if case .existing(let id) = self { return id }
        return nil
    }
}
