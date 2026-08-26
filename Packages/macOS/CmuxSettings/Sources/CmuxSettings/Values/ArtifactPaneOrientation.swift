import Foundation

/// The default axis used when cmux opens a new artifact/Markdown viewer pane.
///
/// `horizontal` preserves the historical right-side split. `vertical` places
/// the new pane below the source surface. Explicit directions supplied by an
/// opener (for example, `cmux markdown open --direction left`) still override
/// this preference.
public enum ArtifactPaneOrientation: String, CaseIterable, Sendable, SettingCodable {
    /// Open the artifact beside the source surface (to the right by default).
    case horizontal
    /// Open the artifact below the source surface.
    case vertical

    /// The direction used when an opener does not provide one explicitly.
    public var defaultDirectionRawValue: String {
        switch self {
        case .horizontal: "right"
        case .vertical: "down"
        }
    }
}
