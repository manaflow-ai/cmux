/// The App Store page's host resources beyond `cmux.app.action.run`
/// (plans/cmux-next/apps-web-DESIGN.md): icons are the host's drawings of cmux's icon pack.
public nonisolated struct AppsPageNativeOps {
    public nonisolated init() {}
    /// `glyph/<name>`: a PNG alpha mask of cmux's pack drawing for a symbol or icon name.
    public static let glyphPrefix = "glyph"
}
