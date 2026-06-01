import ExtensionFoundation
import CmuxExtensionKit
import Foundation

@available(macOS 14.0, *)
/// Discovers installed sidebar extensions that match CMUX's ExtensionKit point.
public struct CMUXSidebarExtensionDiscovery {
    /// Creates an extension discovery helper.
    public init() {}

    /// Lists installed sidebar extensions.
    /// - Parameter extensionPointIdentifier: Extension point identifier to match.
    /// - Returns: Installed extensions sorted by localized name.
    /// - Throws: Errors thrown by ExtensionFoundation discovery.
    public func installedExtensions(
        extensionPointIdentifier: String = CMUXSidebarExtensionPoint.identifier()
    ) async throws -> [CMUXInstalledSidebarExtension] {
        var identities = try AppExtensionIdentity.matching(appExtensionPointIDs: extensionPointIdentifier)
            .makeAsyncIterator()
        guard let update = await identities.next() else { return [] }
        return update.map {
            CMUXInstalledSidebarExtension(
                bundleIdentifier: $0.bundleIdentifier,
                localizedName: $0.localizedName,
                extensionPointIdentifier: $0.extensionPointIdentifier
            )
        }
        .sorted { $0.localizedName < $1.localizedName }
    }
}
