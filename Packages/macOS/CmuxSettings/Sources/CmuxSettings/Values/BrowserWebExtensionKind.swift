import Foundation

/// The source of a configured browser web extension's resources.
public enum BrowserWebExtensionKind: String, Codable, Sendable {
    /// A Safari web extension `.appex` bundled inside an installed app.
    case safariAppExtension

    /// A directory containing an unpacked WebExtension.
    case unpackedDirectory

    /// Returns the standardized effective resource root for `path`.
    ///
    /// Safari app extensions load from `Contents/Resources` inside the `.appex`
    /// bundle; unpacked extensions load directly from their configured folder.
    ///
    /// - Parameter path: The configured `.appex` or unpacked-directory path.
    /// - Returns: The standardized resource-root path WebKit loads.
    public func standardizedResourceRootPath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        switch self {
        case .safariAppExtension:
            return url.browserWebExtensionSafariResourceRootPath
        case .unpackedDirectory:
            return url.browserWebExtensionStandardizedPath
        }
    }
}
