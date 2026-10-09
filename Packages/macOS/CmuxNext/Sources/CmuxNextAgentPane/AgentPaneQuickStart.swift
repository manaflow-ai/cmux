/// Start Agent's Return (`quick.startInBackground`, cx-hkat): the quick
/// panel's chat has started, and goes to the sidebar without taking focus.
public nonisolated struct AgentPaneQuickStart: Sendable, Equatable {
    /// The started acpmux session.
    public var sessionId: String
    /// The session's folder, for the workspace that holds it; nil when unknown.
    public var cwd: String?
    /// A name for that workspace (the prompt's first line); nil for the default name.
    public var name: String?

    public init(sessionId: String, cwd: String?, name: String?) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
    }

    /// The longest name kept; the page sends at most this many characters.
    static let maximumName = 80

    /// `{sessionId, cwd?, name?}`; nil without a session. An empty or
    /// relative folder and an empty name are none.
    init?(params: [String: Any]?) {
        guard let id = params?["sessionId"] as? String, !id.isEmpty else { return nil }
        let cwd = params?["cwd"] as? String
        let name = (params?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(sessionId: id,
                  cwd: cwd.flatMap { $0.hasPrefix("/") && !$0.contains("\0") ? $0 : nil },
                  name: name.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maximumName)) })
    }
}
