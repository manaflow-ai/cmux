import CmuxCloud
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
struct CloudTreeResourceName {
    let resource: SurfaceResource
    let remoteView: SurfaceRemoteView?

    init(resource: SurfaceResource, remoteView: SurfaceRemoteView?) {
        self.resource = resource
        self.remoteView = remoteView
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The user's name for this row, when there is one. Nil means the row is
    /// showing a generated name and a rename has something to offer.
    var chosenName: String? {
        Self.trimmedNonEmpty(remoteView?.name)
    }

    var displayName: String {
        chosenName
            ?? Self.generatedDisplayTitle(resource)
            ?? Self.trimmedNonEmpty(resource.title)
            ?? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop")
    }

    private static func generatedDisplayTitle(_ resource: SurfaceResource) -> String? {
        let prefix = "display:"
        guard resource.id.key.hasPrefix(prefix),
              let number = Int(resource.id.key.dropFirst(prefix.count))
        else { return nil }
        return CloudGuestDisplay.title(for: number)
    }

    var browserName: String {
        chosenName
            ?? Self.trimmedNonEmpty(resource.title)
            ?? String(localized: "cloudTree.browser.untitled", defaultValue: "browser")
    }

    /// The same answer for a reader that holds a resource but not a row: the
    /// rename prompt has to say what the row says, and it is not inside the
    /// switch that picks the row's case.
    ///
    /// Only display and browser rows reach this. The default arm is the browser
    /// rule rather than an exhaustive switch because `SurfaceResourceKind` is
    /// wire-tolerant and a kind added to the wire should not fail to build here;
    /// a terminal has its own name rule and does not call this.
    var label: String {
        switch resource.id.kind {
        case .display:
            return displayName
        default:
            return browserName
        }
    }
}
