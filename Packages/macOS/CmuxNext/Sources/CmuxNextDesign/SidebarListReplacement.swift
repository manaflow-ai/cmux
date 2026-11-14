public import AppKit

/// The person's own workspace list (`cmux.sidebar/1`): an extension, named in
/// `sidebar.workspaceListApp`, that draws the whole list in place of the built-in one. The app layer
/// mounts it on the app platform; the sidebar only hosts the view, so the script, its sandbox and its
/// data stay with the daemon's app host.
///
/// The built-in list is the default and the fallback (DESIGN R5): the sidebar draws it whenever
/// `content` is nil (no extension chosen, the app removed or hidden, apps cannot run here, safe
/// mode), not ready (loading), or has an `errorText` (a script error or a crash).
@MainActor
public protocol SidebarListReplacement: AnyObject {
    /// The chosen extension's list, mounted; nil while the built-in list is the one to draw.
    var content: (any SidebarCustomContent)? { get }
    /// Runs when `content` changed, or its readiness or error did.
    var onContentChange: (() -> Void)? { get set }
    /// Ends the mount and stops watching (the window's sidebar went away or was made again).
    func release()
}
