import CmuxSurfaceCatalogModel
import Foundation

/// The name to show for a display or a browser row.
///
/// Both kinds have two candidate names and they are not equal in standing. The
/// daemon tab's name is user-chosen, set by an explicit rename. The resource's
/// own title is generated: a browser's is the page title, which changes on its
/// own every time the page navigates, and a display's is whatever the provider
/// called it. A name someone typed outranks a name that moves by itself, so
/// the tab name wins and the generated title is the fallback.
///
/// The display row already worked this way and the browser row did not, so
/// renaming a browser had nowhere to show up. This states the rule once, since
/// the row content, the node's searchable title and the context menu each
/// needed it and each had its own version, which is how the browser row ended
/// up with no fallback at all: an untitled browser's searchable title was the
/// empty string, so no amount of typing would find it.
enum CloudTreeResourceName {
    static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The user's name for this row, when there is one. Nil means the row is
    /// showing a generated name and a rename has something to offer.
    static func chosenName(remoteView: SurfaceRemoteView?) -> String? {
        trimmedNonEmpty(remoteView?.name)
    }

    static func display(resource: SurfaceResource, remoteView: SurfaceRemoteView?) -> String {
        chosenName(remoteView: remoteView)
            ?? trimmedNonEmpty(resource.title)
            ?? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop")
    }

    static func browser(resource: SurfaceResource, remoteView: SurfaceRemoteView?) -> String {
        chosenName(remoteView: remoteView)
            ?? trimmedNonEmpty(resource.title)
            ?? String(localized: "cloudTree.browser.untitled", defaultValue: "browser")
    }
}
