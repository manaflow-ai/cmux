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
        extensionPointIdentifier: String = CMUXSidebarExtensionPoint.identifier
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

    /// Lists enabled sidebar extensions using the modern ExtensionFoundation monitor.
    /// - Parameter appExtensionPoint: Extension point declared by the host app.
    /// - Returns: Enabled extensions sorted by localized name.
    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    public func enabledExtensions(
        appExtensionPoint: AppExtensionPoint
    ) async throws -> [CMUXInstalledSidebarExtension] {
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: appExtensionPoint)
        return monitor.state.identities.map {
            CMUXInstalledSidebarExtension(
                bundleIdentifier: $0.bundleIdentifier,
                localizedName: $0.localizedName,
                extensionPointIdentifier: $0.extensionPointIdentifier
            )
        }
        .sorted { $0.localizedName < $1.localizedName }
    }
    #endif
}
