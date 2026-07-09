public import Foundation

/// The partitioned, ordered set of open actions an external deep-link open
/// intent (`application(_:open:)`) resolves to, after the auth callbacks and
/// the app's own cmux-scheme routes have already been handled app-side.
///
/// Built by ``DeepLinkRouting/openPlan(externalFileURLs:directories:)`` from
/// the already-classified file URLs and directories. The app target executes
/// each member in order: it runs every ``terminalFileRequests`` member in a
/// terminal, opens a file preview for every ``filePreviewPaths`` member, and
/// opens a workspace for every ``directories`` member. The plan carries no
/// behavior; it is the typed boundary between the pure URL partitioning (in
/// this package) and the app-target window/workspace routing.
public struct DeepLinkOpenPlan: Sendable, Equatable {
    /// The terminal-eligible file open requests, de-duplicated and in input
    /// order: files whose content type or executable bit means they should be
    /// run in a terminal rather than previewed.
    public let terminalFileRequests: [TerminalDefaultFileOpenRequest]
    /// The percent-decoded, NON-standardized paths of the remaining
    /// (non-terminal-eligible) files, to open in a file preview surface, in
    /// input order with the terminal-eligible files removed. These are the
    /// original URLs' `path(percentEncoded: false)` (not `standardizedFileURL`);
    /// only the dedupe comparison against the terminal-eligible set standardizes
    /// the path. Do not "fix" the planner to map `standardizedFileURL.path`: the
    /// app's file-preview routing receives this exact non-standardized path.
    public let filePreviewPaths: [String]
    /// The ordered, de-duplicated directories to open as workspaces.
    public let directories: [String]

    /// Whether the plan resolves to no open actions at all (no terminal
    /// requests, no preview paths, and no directories), in which case the
    /// deep-link entry returns without preparing an explicit-open intent.
    public var isEmpty: Bool {
        terminalFileRequests.isEmpty && filePreviewPaths.isEmpty && directories.isEmpty
    }

    /// Creates a deep-link open plan.
    /// - Parameters:
    ///   - terminalFileRequests: The terminal-eligible file open requests.
    ///   - filePreviewPaths: The remaining file paths to preview.
    ///   - directories: The directories to open as workspaces.
    public init(
        terminalFileRequests: [TerminalDefaultFileOpenRequest],
        filePreviewPaths: [String],
        directories: [String]
    ) {
        self.terminalFileRequests = terminalFileRequests
        self.filePreviewPaths = filePreviewPaths
        self.directories = directories
    }
}
