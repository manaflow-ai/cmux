import CmuxFoundation
import SwiftUI

/// Concrete leaf types keep resource formatting out of the outline's large
/// ViewBuilder switch, where overloaded formatting can defeat type inference.
@MainActor
extension CloudTreeRowContentView {
    func displayRow(
        resource: SurfaceResource,
        remoteView: SurfaceRemoteView?
    ) -> CloudTreeLeafRow<EmptyView> {
        let fallback = resource.title.isEmpty
            ? String(localized: "cloudTree.node.desktop", defaultValue: "Desktop")
            : resource.title
        let title = Self.nonEmptyTrimmed(remoteView?.name) ?? fallback
        return CloudTreeLeafRow(
            style: style,
            icon: "display",
            tint: CloudTreeIconPalette.display,
            title: title,
            detail: Self.text(for: resource)
        )
    }

    func browserRow(_ row: CloudTreeBrowserRow) -> CloudTreeLeafRow<EmptyView> {
        let title = row.resource.title.isEmpty
            ? String(localized: "cloudTree.browser.untitled", defaultValue: "browser")
            : row.resource.title
        return CloudTreeLeafRow(
            style: style,
            icon: "globe",
            tint: CloudTreeIconPalette.browser,
            title: title,
            detail: CloudTreeBrowserDetail.text(for: row)
        )
    }

    func portRow(resource: SurfaceResource, url: String?) -> CloudTreeLeafRow<EmptyView> {
        let port: String? = (resource.id.forwardedPort ?? resource.port).map { String($0) }
        let link: String? = url.map { CloudTreePortLinkText.displayText(forURL: $0) }
        let title = link ?? port ?? resource.title
        let detail: String? = url == nil && resource.detail?.isEmpty == false ? resource.detail : nil
        return CloudTreeLeafRow(
            style: style,
            icon: "network",
            tint: CloudTreeIconPalette.browser,
            title: title,
            titleIsLink: url != nil,
            detail: detail
        )
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
