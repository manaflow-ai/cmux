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
///
/// Deciding is filesystem work for a `.url` file, whose bytes name the page it points at, so the
/// decision is reached through ``deciding(fileURL:)`` off the main thread and published to the view
/// rather than computed inside `body`.
public enum CustomSidebarMountDecision: Equatable, Sendable {
    /// Render as a page.
    case web(CustomSidebarWebSource)
    /// Render through the sidebar interpreter.
    case interpreted(URL)
    /// Render nothing: the file is missing, unrecognised, or a web source that named nothing
    /// loadable.
    case unavailable

    /// Decides how to mount an already-resolved sidebar file, without blocking the caller.
    ///
    /// The `.url` branch reads the file; every other answer follows from the extension. The read
    /// itself lives in ``CustomSidebarSource/classifying(fileURL:)``, which is `@concurrent`, so
    /// awaiting this from the main actor puts no filesystem work on the main thread.
    ///
    /// - Parameter fileURL: The file the sidebar name currently resolves to, or `nil` when it
    ///   resolves to nothing.
    public static func deciding(fileURL: URL?) async -> CustomSidebarMountDecision {
        guard let fileURL else { return .unavailable }
        if let decided = decidedWithoutReading(fileURL: fileURL) { return decided }
        return Self(source: await CustomSidebarSource.classifying(fileURL: fileURL))
    }

    /// The decision for a file whose kind follows from its extension alone, or `nil` for a `.url`
    /// file, whose bytes decide it.
    ///
    /// Lets a caller that already knows its file — a Dock pane, which is opened on one — render the
    /// correct thing on its first frame with no filesystem access at all.
    ///
    /// - Parameter fileURL: The candidate file.
    public static func decidedWithoutReading(fileURL: URL) -> CustomSidebarMountDecision? {
        switch CustomSidebarSource.classifyWithoutReading(fileURL: fileURL) {
        case let .decided(source):
            return Self(source: source)
        case .needsURLFileRead:
            return nil
        }
    }

    private init(source: CustomSidebarSource?) {
        switch source {
        case let .web(source):
            self = .web(source)
        case let .interpreted(url):
            self = .interpreted(url)
        case nil:
            self = .unavailable
        }
    }
}
