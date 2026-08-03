#if os(iOS)
import UIKit

/// A system presentation prepared by an artifact file action.
public enum ChatArtifactFileActionPresentation: Identifiable, Equatable, Sendable {
    /// Presents the standard activity controller for a local file.
    case share(URL)
    /// Presents the Files document picker in export-as-copy mode.
    case save(URL)

    /// Stable identity for system-controller presentation.
    public var id: String {
        switch self {
        case .share(let url):
            return "share:\(url.path)"
        case .save(let url):
            return "save:\(url.path)"
        }
    }

    public var fileURL: URL {
        switch self {
        case .share(let url), .save(let url):
            return url
        }
    }
}
#endif
