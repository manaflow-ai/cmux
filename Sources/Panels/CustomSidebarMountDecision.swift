import CmuxFoundation
import Foundation

/// What a resolved custom sidebar file should be mounted as.
///
/// Both surfaces that host a custom sidebar — the workspace rail and a Dock pane — used to ask
/// "is this a web source?" and treat everything else as interpreted. That is one case short. A
/// `.url` file naming nothing loadable classifies as neither: it is a web sidebar that failed, and
/// falling through handed the file to the interpreter, which does not check extensions and decodes
/// any unrecognised file as declarative JSON. A `.url` file whose bytes happen to be sidebar DSL
/// would therefore render with live action dispatch — the privileged lane — from a file the web
/// path had just refused. Making the third case explicit is what closes that.
enum CustomSidebarMountDecision: Equatable {
    /// Render as a page.
    case web(CustomSidebarWebSource)
    /// Render through the sidebar interpreter.
    case interpreted(URL)
    /// Render nothing: the file is missing, unrecognised, or a web source that named nothing
    /// loadable.
    case unavailable

    /// Decides how to mount an already-resolved sidebar file.
    ///
    /// - Parameter fileURL: The file the sidebar name currently resolves to, or `nil` when it
    ///   resolves to nothing.
    init(fileURL: URL?) {
        guard let fileURL else {
            self = .unavailable
            return
        }
        switch CustomSidebarSource.classify(fileURL: fileURL) {
        case let .web(source):
            self = .web(source)
        case let .interpreted(url):
            self = .interpreted(url)
        case nil:
            self = .unavailable
        }
    }
}
