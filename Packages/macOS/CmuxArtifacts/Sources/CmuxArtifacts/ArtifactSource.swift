/// The bounded provenance vocabulary for captured artifacts.
public enum ArtifactSource: String, Codable, CaseIterable, Sendable {
    /// An OSC-8 hyperlink emitted by a terminal.
    case terminalOSC8
    /// A plain URL detected in terminal output.
    case terminalURL
    /// A local path detected in terminal output.
    case terminalPath
    /// An artifact explicitly produced by an agent/tool.
    case agent
    /// A browser page or browser-generated HTML artifact.
    case browser
    /// A file saved by the browser download delegate.
    case browserDownload
    /// A generated/local file submitted by a producer hook.
    case generated
    /// A user-selected or manually typed artifact.
    case manual
    /// A record migrated from the pre-Artifacts Links snapshot.
    case migratedLink

    /// Decodes unknown historical values as a safe manual provenance.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self(rawValue: raw) ?? .manual
    }
}
