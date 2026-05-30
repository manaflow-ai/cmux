import Foundation

/// Installed ExtensionKit sidebar extension discovered on the current Mac.
public struct CMUXInstalledSidebarExtension: Identifiable, Equatable, Sendable {
    /// Stable bundle identifier used for SwiftUI identity.
    public var id: String { bundleIdentifier }
    /// Extension bundle identifier.
    public var bundleIdentifier: String
    /// Localized extension display name.
    public var localizedName: String
    /// Extension point identifier declared by the extension.
    public var extensionPointIdentifier: String

    /// Creates an installed extension summary.
    /// - Parameters:
    ///   - bundleIdentifier: Extension bundle identifier.
    ///   - localizedName: Localized extension display name.
    ///   - extensionPointIdentifier: Extension point identifier declared by the extension.
    public init(
        bundleIdentifier: String,
        localizedName: String,
        extensionPointIdentifier: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.extensionPointIdentifier = extensionPointIdentifier
    }
}
