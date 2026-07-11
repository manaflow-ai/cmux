import Foundation

extension URL {
    /// The standardized filesystem path represented by this URL.
    public var browserWebExtensionStandardizedPath: String {
        standardizedFileURL.path
    }

    /// The resource root WebKit uses for a Safari app extension URL.
    public var browserWebExtensionSafariResourceRootPath: String {
        let standardizedURL = standardizedFileURL
        guard standardizedURL.pathExtension == "appex" else {
            return standardizedURL.path
        }
        return standardizedURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .standardizedFileURL
            .path
    }
}
