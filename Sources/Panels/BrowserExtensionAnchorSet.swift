import AppKit

/// The anchors of the pinned action buttons, by extension id.
@MainActor
final class BrowserExtensionAnchorSet {
    private var anchors: [String: BrowserExtensionAnchor] = [:]

    /// The anchor of `id`'s button, created on first use.
    func anchor(for id: String) -> BrowserExtensionAnchor {
        if let anchor = anchors[id] { return anchor }
        let anchor = BrowserExtensionAnchor()
        anchors[id] = anchor
        return anchor
    }

    /// The on-screen frame of `id`'s pinned button, if it is shown.
    func windowFrame(for id: String) -> CGRect? { anchors[id]?.windowFrame }
}
