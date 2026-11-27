import Foundation

/// `SavedTabGroupSnapshot` is generated from the schema's `SavedTabGroupRecord` (swift_app/bindings.json, Tree family).

/// One member of a saved group: `{kind:"terminal", terminal_id, cwd, title}`
/// or `{kind:"browser", url, engine, profile_id, title}`.
public struct SavedTab: Sendable, Hashable, Decodable {
    /// `.pty` for wire `"terminal"`, `.browser` for `"browser"`.
    public var kind: TabKind
    public var title: String
    public var cwd: String?
    public var url: String?
    /// Reattached when the terminal still runs.
    public var terminalID: TerminalID?
    /// Frontend browser engine (`"webkit"`/`"cef"`); nil for a CDP browser.
    public var engine: String?
    public var profileID: String?

    public init(kind: TabKind, title: String = "", cwd: String? = nil, url: String? = nil, terminalID: TerminalID? = nil,
                engine: String? = nil, profileID: String? = nil) {
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.url = url
        self.terminalID = terminalID
        self.engine = engine
        self.profileID = profileID
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, cwd, url, engine
        case terminalID = "terminal_id"
        case profileID = "profile_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "terminal"
        kind = rawKind == "terminal" ? .pty : TabKind(rawValue: rawKind)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        terminalID = try c.decodeIfPresent(TerminalID.self, forKey: .terminalID)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
    }
}
