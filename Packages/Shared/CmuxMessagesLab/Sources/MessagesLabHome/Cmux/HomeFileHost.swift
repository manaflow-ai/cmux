import AppKit

/// cmux: the host's file actions for Home attachments. A click opens the file in the host (cmux
/// shows it on the right of the chat, never in Finder) and the right-click menu is the host's
/// file menu (Open in Right Pane, Open With, Reveal, Copy Path, Quick Look, Share). With no host
/// set the transcript keeps the system open ("Open in Default App"), so the vendored package
/// still works alone.
public protocol HomeFileHost: AnyObject {
    /// Opens `file` (a local copy named like the attachment) where the host shows files.
    @MainActor func open(_ file: URL)

    /// The menu rows for a file named `name`. `resolve` fetches the local copy when a row runs
    /// (the rows are built from the name alone, so the menu shows at once).
    @MainActor func menuItems(forFileNamed name: String, resolve: @escaping @MainActor @Sendable () async -> URL?) -> [NSMenuItem]
}
