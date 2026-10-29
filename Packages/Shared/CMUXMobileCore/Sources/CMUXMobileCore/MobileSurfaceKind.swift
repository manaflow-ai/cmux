/// A mobile surface kind identified by its open wire string.
///
/// Known kinds have static constants, while unknown raw values remain valid so
/// older clients can preserve and route surface kinds introduced by newer Macs.
public struct MobileSurfaceKind: RawRepresentable, Codable, Hashable, Sendable {
    /// The surface kind's wire identifier.
    public let rawValue: String

    /// Creates a surface kind from its wire identifier.
    /// - Parameter rawValue: The open surface-kind string.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Decodes the kind directly from its open wire string.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    /// Encodes the kind directly as its open wire string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// A Ghostty terminal surface.
    public static let terminal = MobileSurfaceKind(rawValue: "terminal")
    /// A browser surface.
    public static let browser = MobileSurfaceKind(rawValue: "browser")
    /// A markdown preview surface.
    public static let markdown = MobileSurfaceKind(rawValue: "markdown")
    /// A file preview surface.
    public static let filePreview = MobileSurfaceKind(rawValue: "filePreview")
    /// A right-sidebar tool hosted as a surface.
    public static let rightSidebarTool = MobileSurfaceKind(rawValue: "rightSidebarTool")
    /// A custom sidebar hosted as a surface.
    public static let customSidebar = MobileSurfaceKind(rawValue: "customSidebar")
    /// An agent-session surface.
    public static let agentSession = MobileSurfaceKind(rawValue: "agentSession")
    /// A project surface.
    public static let project = MobileSurfaceKind(rawValue: "project")
    /// A browser surface owned by an extension.
    public static let extensionBrowser = MobileSurfaceKind(rawValue: "extensionBrowser")
    /// A workspace todo surface.
    public static let todo = MobileSurfaceKind(rawValue: "todo")
    /// A transient Cloud VM loading surface.
    public static let cloudVMLoading = MobileSurfaceKind(rawValue: "cloudVMLoading")
}
