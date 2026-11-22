/// What to draw for an icon name: its pack layers, or an SF Symbol.
public nonisolated enum IconResolution: Hashable, Sendable {
    case drawing([IconLayer])
    case system(String)

    /// The SF Symbol for a name neither the pack nor the catalog knows.
    public static let unknownSymbol = "questionmark.square.dashed"
}
