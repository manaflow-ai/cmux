import Foundation

extension URL {
    /// The canonical filesystem path represented by this URL, with symbolic links resolved.
    public var browserWebExtensionStandardizedPath: String {
        standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The canonical resource root WebKit uses for a Safari app extension URL.
    public var browserWebExtensionSafariResourceRootPath: String {
        let standardizedURL = standardizedFileURL
        let resourceRootURL: URL
        if standardizedURL.pathExtension == "appex" {
            resourceRootURL = standardizedURL
                .appendingPathComponent("Contents/Resources", isDirectory: true)
                .standardizedFileURL
        } else {
            resourceRootURL = standardizedURL
        }
        return resourceRootURL.resolvingSymlinksInPath().path
    }
}
