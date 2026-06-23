/// The kind of content a ``Panel`` hosts.
///
/// The ``RawValue`` strings are persisted in session snapshots and carried on
/// the wire, so they are frozen; the custom `Codable` conformance tolerates the
/// historical lowercased spellings (`"filepreview"`, etc.) that earlier builds
/// wrote.
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
    case markdown
    case filePreview = "filepreview"
    case rightSidebarTool
    case agentSession
    case project
    case extensionBrowser

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let type = Self(rawValue: rawValue) {
            self = type
            return
        }
        if rawValue.lowercased() == Self.filePreview.rawValue {
            self = .filePreview
            return
        }
        if rawValue.lowercased() == Self.rightSidebarTool.rawValue.lowercased() {
            self = .rightSidebarTool
            return
        }
        if rawValue.lowercased() == Self.agentSession.rawValue.lowercased() {
            self = .agentSession
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unknown panel type: \(rawValue)"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
