import Foundation

/// Moves extension-directory enumeration and metadata reads off the main actor.
@available(macOS 15.4, *)
actor BrowserWebExtensionDirectoryRepository {
    func candidateURLs(in directory: URL) -> [URL] {
        BrowserWebExtensionsManager.candidateURLs(in: directory)
    }
}
